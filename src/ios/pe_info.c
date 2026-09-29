#include "pe_info.h"

#include <stdio.h>
#include <string.h>

#define IMAGE_FILE_MACHINE_I386    0x014c
#define IMAGE_FILE_MACHINE_ARMNT   0x01c4
#define IMAGE_FILE_MACHINE_AMD64   0x8664
#define IMAGE_FILE_MACHINE_ARM64   0xaa64
#define IMAGE_FILE_MACHINE_ARM64EC 0xa641
#define IMAGE_FILE_MACHINE_ARM64X  0xa64e

#define IMAGE_FILE_DLL             0x2000

/* Optional-header magic. */
#define PE32_MAGIC     0x010b
#define PE32PLUS_MAGIC 0x020b

#define OPT_SUBSYSTEM_OFFSET 68

static int read_at(FILE *f, long off, void *buf, size_t len) {
  if (off < 0) return -1;
  if (fseek(f, off, SEEK_SET) != 0) return -1;
  return fread(buf, 1, len, f) == len ? 0 : -1;
}

static uint16_t rd16(const unsigned char *p) {
  return (uint16_t)(p[0] | (p[1] << 8));
}

static uint32_t rd32(const unsigned char *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
         ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void fail(char *err, size_t errlen, const char *msg) {
  if (err && errlen) snprintf(err, errlen, "%s", msg);
}

const char *pe_arch_name(pe_arch a) {
  switch (a) {
  case PE_ARCH_I386:    return "x86 (32-bit)";
  case PE_ARCH_AMD64:   return "x86-64";
  case PE_ARCH_ARM64:   return "ARM64";
  case PE_ARCH_ARM64EC: return "ARM64EC";
  case PE_ARCH_ARM64X:  return "ARM64X";
  case PE_ARCH_ARMNT:   return "ARM32";
  default:              return "unknown";
  }
}

int pe_arch_runnable(pe_arch a, int have_wow64) {
  switch (a) {
  case PE_ARCH_ARM64:
  case PE_ARCH_ARM64EC:
  case PE_ARCH_ARM64X:
  case PE_ARCH_AMD64:
    return 1;
  case PE_ARCH_I386:
    return have_wow64 ? 1 : 0;
  default:
    /* ARMNT has no runtime here and never will: Wine's 32-bit ARM PE target is
     * not built, and no emulator in this tree targets it. */
    return 0;
  }
}

pe_arch pe_arch_from_machine(uint16_t m) {
  switch (m) {
  case IMAGE_FILE_MACHINE_I386:    return PE_ARCH_I386;
  case IMAGE_FILE_MACHINE_AMD64:   return PE_ARCH_AMD64;
  case IMAGE_FILE_MACHINE_ARM64:   return PE_ARCH_ARM64;
  case IMAGE_FILE_MACHINE_ARM64EC: return PE_ARCH_ARM64EC;
  case IMAGE_FILE_MACHINE_ARM64X:  return PE_ARCH_ARM64X;
  case IMAGE_FILE_MACHINE_ARMNT:   return PE_ARCH_ARMNT;
  default:                         return PE_ARCH_UNKNOWN;
  }
}

int pe_info_read(const char *path, pe_info *out, char *err, size_t errlen) {
  unsigned char buf[24];
  FILE *f;
  long pe_off;
  uint16_t opt_size, magic, characteristics;

  memset(out, 0, sizeof(*out));

  if (!(f = fopen(path, "rb"))) {
    fail(err, errlen, "cannot open file");
    return -1;
  }

  /* MZ, then e_lfanew at 0x3c. */
  if (read_at(f, 0, buf, 2) != 0 || buf[0] != 'M' || buf[1] != 'Z') {
    fail(err, errlen, "not a PE image (no MZ signature)");
    fclose(f);
    return -1;
  }
  if (read_at(f, 0x3c, buf, 4) != 0) {
    fail(err, errlen, "truncated DOS header");
    fclose(f);
    return -1;
  }
  pe_off = (long)rd32(buf);

  if (pe_off < 0x40 || pe_off > (1 << 30)) {
    fail(err, errlen, "not a PE image (bad e_lfanew)");
    fclose(f);
    return -1;
  }

  /* PE\0\0 + IMAGE_FILE_HEADER (20 bytes). */
  if (read_at(f, pe_off, buf, 24) != 0) {
    fail(err, errlen, "truncated PE header");
    fclose(f);
    return -1;
  }
  if (memcmp(buf, "PE\0\0", 4) != 0) {
    fail(err, errlen, "not a PE image (no PE signature)");
    fclose(f);
    return -1;
  }

  out->machine    = rd16(buf + 4);
  out->arch       = pe_arch_from_machine(out->machine);
  opt_size        = rd16(buf + 20);
  characteristics = rd16(buf + 22);
  out->is_dll     = (characteristics & IMAGE_FILE_DLL) ? 1 : 0;

  if (opt_size < OPT_SUBSYSTEM_OFFSET + 2) {
    fclose(f);
    return 0;
  }

  if (read_at(f, pe_off + 24, buf, 2) != 0) {
    fail(err, errlen, "truncated optional header");
    fclose(f);
    return -1;
  }
  magic = rd16(buf);
  if (magic != PE32_MAGIC && magic != PE32PLUS_MAGIC) {
    fail(err, errlen, "unrecognised optional header magic");
    fclose(f);
    return -1;
  }
  out->is_64bit = (magic == PE32PLUS_MAGIC);

  if (read_at(f, pe_off + 24 + OPT_SUBSYSTEM_OFFSET, buf, 2) != 0) {
    fail(err, errlen, "truncated optional header");
    fclose(f);
    return -1;
  }
  {
    uint16_t s = rd16(buf);
    out->subsystem = (s == 2 || s == 3) ? (pe_subsystem)s : PE_SUBSYSTEM_UNKNOWN;
  }

  fclose(f);
  return 0;
}

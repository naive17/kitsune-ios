#ifndef IOS_PE_INFO_H
#define IOS_PE_INFO_H

#include <stddef.h>
#include <stdint.h>

typedef enum {
  PE_ARCH_UNKNOWN = 0,
  PE_ARCH_I386,     /* 0x014c -- needs WoW64 + libwow64fex.dll */
  PE_ARCH_AMD64,    /* 0x8664 -- needs ARM64EC Wine + libarm64ecfex.dll */
  PE_ARCH_ARM64,    /* 0xaa64 -- native */
  PE_ARCH_ARM64EC,  /* 0xa641 -- native, x86-compatible ABI */
  PE_ARCH_ARM64X,   /* 0xa64e -- hybrid, native */
  PE_ARCH_ARMNT,    /* 0x01c4 -- 32-bit ARM, no runtime for it here */
} pe_arch;

typedef enum {
  PE_SUBSYSTEM_UNKNOWN = 0,
  PE_SUBSYSTEM_CONSOLE = 3,
  PE_SUBSYSTEM_GUI     = 2,
} pe_subsystem;

typedef struct {
  pe_arch      arch;
  pe_subsystem subsystem;
  uint16_t     machine;      /* the raw field, for logging an unknown value */
  int          is_dll;
  int          is_64bit;     /* optional-header magic was PE32+ */
} pe_info;

int pe_info_read(const char *path, pe_info *out, char *err, size_t errlen);

/* Stable short names for logs and the library UI: "ARM64", "x86-64", ... */
const char *pe_arch_name(pe_arch a);

pe_arch pe_arch_from_machine(uint16_t machine);

int pe_arch_runnable(pe_arch a, int have_wow64);

#endif

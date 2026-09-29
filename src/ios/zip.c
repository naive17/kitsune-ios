#include "zip.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <zlib.h>

#define SIG_LOCAL         0x04034b50u
#define SIG_CENTRAL       0x02014b50u
#define SIG_EOCD          0x06054b50u
#define SIG_ZIP64_EOCD    0x06064b50u
#define SIG_ZIP64_LOCATOR 0x07064b50u

#define FLAG_ENCRYPTED       0x0001
#define FLAG_DATA_DESCRIPTOR 0x0008

#define METHOD_STORE   0
#define METHOD_DEFLATE 8

#define MAX_NAME 4096

#define CHUNK (256 * 1024)

struct zip_io_buf {
  unsigned char in[CHUNK];
  unsigned char out[CHUNK];
};

typedef struct {
  char    *name;
  uint64_t comp_size;
  uint64_t size;
  uint64_t local_offset;
  uint32_t crc;
  uint16_t method;
  uint16_t flags;
  uint16_t dos_time, dos_date;
  uint32_t external_attrs;
  int      is_dir;
} zip_entry;

struct zip_reader {
  FILE      *f;
  zip_entry *entries;
  size_t     count;
};

static uint16_t rd16(const unsigned char *p) {
  return (uint16_t)(p[0] | (p[1] << 8));
}

static uint32_t rd32(const unsigned char *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
         ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint64_t rd64(const unsigned char *p) {
  return (uint64_t)rd32(p) | ((uint64_t)rd32(p + 4) << 32);
}

static void fail(char *err, size_t errlen, const char *msg) {
  if (err && errlen) snprintf(err, errlen, "%s", msg);
}

static int file_read(void *ctx, void *buf, size_t len) {
  if (!buf) return fseeko((FILE *)ctx, (off_t)len, SEEK_CUR);
  return fread(buf, 1, len, (FILE *)ctx) == len ? 0 : -1;
}

static int read_at(FILE *f, uint64_t off, void *buf, size_t len) {
  if (off > (uint64_t)INT64_MAX) return -1;
  if (fseeko(f, (off_t)off, SEEK_SET) != 0) return -1;
  return fread(buf, 1, len, f) == len ? 0 : -1;
}

/* ------------------------------------------------------------------ paths */

int zip_safe_path(const char *name, char *out, size_t outlen) {
  size_t n, w = 0;
  const char *p;

  if (!name || !*name) return -1;
  n = strlen(name);
  if (n >= outlen) return -1;

  if (name[0] == '/' || name[0] == '\\') return -1;
  /* "C:..." and "C:/..." alike. */
  if (n >= 2 && name[1] == ':') return -1;

  p = name;
  while (*p) {
    const char *seg = p;
    size_t seglen;

    while (*p && *p != '/' && *p != '\\') p++;
    seglen = (size_t)(p - seg);

    if (seglen == 0) {
      /* "a//b" and a trailing separator: skip, do not emit an empty part. */
      if (*p) p++;
      continue;
    }
    if (seglen == 1 && seg[0] == '.') {
      if (*p) p++;
      continue;
    }
    if (seglen == 2 && seg[0] == '.' && seg[1] == '.') return -1;

    if (w + seglen + (w ? 1 : 0) >= outlen) return -1;
    if (w) out[w++] = '/';
    memcpy(out + w, seg, seglen);
    w += seglen;

    if (*p) p++;
  }

  if (w == 0) return -1;
  out[w] = '\0';
  return 0;
}

/* mkdir -p, on a path that zip_safe_path has already validated. */
static int make_dirs(const char *path) {
  char tmp[MAX_NAME];
  size_t len = strlen(path);
  size_t i;

  if (len >= sizeof(tmp)) return -1;
  memcpy(tmp, path, len + 1);

  for (i = 1; i < len; i++) {
    if (tmp[i] != '/') continue;
    tmp[i] = '\0';
    if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return -1;
    tmp[i] = '/';
  }
  if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return -1;
  return 0;
}

static int make_parent_dirs(const char *full) {
  char tmp[MAX_NAME];
  char *slash;
  size_t len = strlen(full);

  if (len >= sizeof(tmp)) return -1;
  memcpy(tmp, full, len + 1);
  if (!(slash = strrchr(tmp, '/'))) return 0;
  *slash = '\0';
  if (!tmp[0]) return 0;
  return make_dirs(tmp);
}

/* ------------------------------------------------------- central directory */

static int find_eocd(FILE *f, unsigned char *rec, uint64_t *rec_off,
                     char *err, size_t errlen) {
  off_t fsize;
  size_t window;
  unsigned char *buf;
  uint64_t base;
  long i;

  if (fseeko(f, 0, SEEK_END) != 0) { fail(err, errlen, "seek failed"); return -1; }
  fsize = ftello(f);
  if (fsize < 22) { fail(err, errlen, "file is too small to be a zip"); return -1; }

  window = 22 + 65535;
  if ((off_t)window > fsize) window = (size_t)fsize;
  base = (uint64_t)fsize - window;

  if (!(buf = malloc(window))) { fail(err, errlen, "out of memory"); return -1; }
  if (read_at(f, base, buf, window) != 0) {
    free(buf);
    fail(err, errlen, "short read looking for the central directory");
    return -1;
  }

  for (i = (long)window - 22; i >= 0; i--) {
    if (rd32(buf + i) == SIG_EOCD) {
      memcpy(rec, buf + i, 22);
      *rec_off = base + (uint64_t)i;
      free(buf);
      return 0;
    }
  }
  free(buf);
  fail(err, errlen, "not a zip archive (no end-of-central-directory record)");
  return -1;
}

static int resolve_zip64(FILE *f, uint64_t eocd_off, uint64_t *cd_off,
                         uint64_t *cd_size, uint64_t *entries) {
  unsigned char loc[20], z64[56];
  uint64_t z64_off;

  if (*cd_off != 0xffffffffu && *entries != 0xffffu && *cd_size != 0xffffffffu)
    return 0;
  if (eocd_off < 20) return -1;
  if (read_at(f, eocd_off - 20, loc, 20) != 0) return -1;
  if (rd32(loc) != SIG_ZIP64_LOCATOR) return -1;

  z64_off = rd64(loc + 8);
  if (read_at(f, z64_off, z64, 56) != 0) return -1;
  if (rd32(z64) != SIG_ZIP64_EOCD) return -1;

  *entries = rd64(z64 + 32);
  *cd_size = rd64(z64 + 40);
  *cd_off  = rd64(z64 + 48);
  return 0;
}

static void apply_zip64_extra(const unsigned char *extra, size_t len,
                              zip_entry *e) {
  size_t off = 0;

  while (off + 4 <= len) {
    uint16_t id   = rd16(extra + off);
    uint16_t elen = rd16(extra + off + 2);
    const unsigned char *p = extra + off + 4;
    size_t left = elen;

    if (off + 4 + elen > len) return;
    if (id == 0x0001) {
      if (e->size == 0xffffffffu && left >= 8)      { e->size = rd64(p); p += 8; left -= 8; }
      if (e->comp_size == 0xffffffffu && left >= 8) { e->comp_size = rd64(p); p += 8; left -= 8; }
      if (e->local_offset == 0xffffffffu && left >= 8) { e->local_offset = rd64(p); }
      return;
    }
    off += 4 + elen;
  }
}

int zip_open(const char *path, zip_reader **out, char *err, size_t errlen) {
  unsigned char eocd[22];
  uint64_t eocd_off, cd_off, cd_size, entries, pos;
  unsigned char *cd = NULL;
  zip_reader *z;
  size_t i;

  *out = NULL;
  if (!(z = calloc(1, sizeof(*z)))) { fail(err, errlen, "out of memory"); return -1; }
  if (!(z->f = fopen(path, "rb"))) {
    fail(err, errlen, "cannot open archive");
    free(z);
    return -1;
  }
  if (find_eocd(z->f, eocd, &eocd_off, err, errlen) != 0) goto bad;

  entries = rd16(eocd + 10);
  cd_size = rd32(eocd + 12);
  cd_off  = rd32(eocd + 16);
  resolve_zip64(z->f, eocd_off, &cd_off, &cd_size, &entries);

  if (entries == 0) {
    fail(err, errlen, "archive is empty");
    goto bad;
  }
  /* A central directory larger than the file cannot be honest. */
  if (cd_size > (uint64_t)1 << 32 || cd_off > eocd_off) {
    fail(err, errlen, "central directory is out of range");
    goto bad;
  }
  if (!(cd = malloc((size_t)cd_size))) { fail(err, errlen, "out of memory"); goto bad; }
  if (read_at(z->f, cd_off, cd, (size_t)cd_size) != 0) {
    fail(err, errlen, "short read on the central directory");
    goto bad;
  }
  if (!(z->entries = calloc((size_t)entries, sizeof(zip_entry)))) {
    fail(err, errlen, "out of memory");
    goto bad;
  }

  pos = 0;
  for (i = 0; i < entries; i++) {
    zip_entry *e = &z->entries[i];
    uint16_t name_len, extra_len, comment_len;
    size_t name_end;

    if (pos + 46 > cd_size || rd32(cd + pos) != SIG_CENTRAL) {
      fail(err, errlen, "malformed central directory");
      goto bad;
    }
    e->flags          = rd16(cd + pos + 8);
    e->method         = rd16(cd + pos + 10);
    e->dos_time       = rd16(cd + pos + 12);
    e->dos_date       = rd16(cd + pos + 14);
    e->crc            = rd32(cd + pos + 16);
    e->comp_size      = rd32(cd + pos + 20);
    e->size           = rd32(cd + pos + 24);
    name_len          = rd16(cd + pos + 28);
    extra_len         = rd16(cd + pos + 30);
    comment_len       = rd16(cd + pos + 32);
    e->external_attrs = rd32(cd + pos + 38);
    e->local_offset   = rd32(cd + pos + 42);

    name_end = (size_t)pos + 46 + name_len;
    if (name_end > cd_size || name_len == 0 || name_len >= MAX_NAME) {
      fail(err, errlen, "malformed entry name");
      goto bad;
    }
    if (!(e->name = malloc((size_t)name_len + 1))) {
      fail(err, errlen, "out of memory");
      goto bad;
    }
    memcpy(e->name, cd + pos + 46, name_len);
    e->name[name_len] = '\0';
    /* An embedded NUL would truncate the name and could smuggle a second one
     * past validation. Names are counted, not terminated, so this is legal in
     * the container and must be rejected here. */
    if (strlen(e->name) != name_len) {
      fail(err, errlen, "entry name contains a NUL");
      goto bad;
    }

    if (extra_len)
      apply_zip64_extra(cd + name_end, extra_len, e);

    {
      size_t l = strlen(e->name);
      e->is_dir = (l && (e->name[l - 1] == '/' || e->name[l - 1] == '\\'));
    }
    z->count++;
    pos = name_end + extra_len + comment_len;
  }

  free(cd);
  *out = z;
  return 0;

bad:
  free(cd);
  zip_close(z);
  return -1;
}

void zip_close(zip_reader *z) {
  size_t i;

  if (!z) return;
  for (i = 0; i < z->count; i++) free(z->entries[i].name);
  free(z->entries);
  if (z->f) fclose(z->f);
  free(z);
}

size_t zip_count(const zip_reader *z) { return z ? z->count : 0; }

const char *zip_entry_name(const zip_reader *z, size_t i) {
  return (z && i < z->count) ? z->entries[i].name : NULL;
}

int zip_entry_is_dir(const zip_reader *z, size_t i) {
  return (z && i < z->count) ? z->entries[i].is_dir : 0;
}

uint64_t zip_entry_size(const zip_reader *z, size_t i) {
  return (z && i < z->count) ? z->entries[i].size : 0;
}

/* ------------------------------------------------------------- extraction */

/* Where the entry's data starts: past its local header, whose name and extra
 * lengths may differ from the central directory's. */
static int local_data_offset(FILE *f, const zip_entry *e, uint64_t *out) {
  unsigned char hdr[30];

  if (read_at(f, e->local_offset, hdr, 30) != 0) return -1;
  if (rd32(hdr) != SIG_LOCAL) return -1;
  *out = e->local_offset + 30 + rd16(hdr + 26) + rd16(hdr + 28);
  return 0;
}

static int write_stored(zip_read_fn read, void *in, FILE *outf, uint64_t len, uint32_t *crc,
                        struct zip_io_buf *io) {
  unsigned char *buf = io->in;

  while (len) {
    size_t want = len > CHUNK ? CHUNK : (size_t)len;

    if (read(in, buf, want) != 0) return -1;
    if (fwrite(buf, 1, want, outf) != want) return -1;
    *crc = (uint32_t)crc32(*crc, buf, (unsigned)want);
    len -= want;
  }
  return 0;
}

static int write_deflated(zip_read_fn read, void *in, FILE *outf, uint64_t comp_len, uint32_t *crc,
                          struct zip_io_buf *io) {
  unsigned char *inbuf = io->in, *outbuf = io->out;
  z_stream s;
  int rc = -1, zret = Z_OK;

  memset(&s, 0, sizeof(s));
  /* Raw deflate: the zip container supplies no zlib header. */
  if (inflateInit2(&s, -MAX_WBITS) != Z_OK) return -1;

  while (zret != Z_STREAM_END) {
    size_t want;

    if (s.avail_in == 0) {
      if (comp_len == 0) goto done;  /* truncated stream */
      want = comp_len > CHUNK ? CHUNK : (size_t)comp_len;
      if (read(in, inbuf, want) != 0) goto done;
      comp_len -= want;
      s.next_in = inbuf;
      s.avail_in = (unsigned)want;
    }
    s.next_out = outbuf;
    s.avail_out = CHUNK;
    zret = inflate(&s, Z_NO_FLUSH);
    if (zret != Z_OK && zret != Z_STREAM_END && zret != Z_BUF_ERROR) goto done;
    {
      size_t got = CHUNK - s.avail_out;

      if (got) {
        if (fwrite(outbuf, 1, got, outf) != got) goto done;
        *crc = (uint32_t)crc32(*crc, outbuf, (unsigned)got);
      } else if (zret == Z_BUF_ERROR && s.avail_in == 0 && comp_len == 0) {
        goto done;  /* no progress possible and no input left */
      }
    }
  }
  rc = 0;
done:
  inflateEnd(&s);
  return rc;
}

int zip_extract_all(zip_reader *z, const char *destdir,
                    zip_progress cb, void *user,
                    size_t *skipped, char *err, size_t errlen) {
  return zip_extract_all_ex(z, destdir, cb, user, NULL, NULL, skipped, err, errlen);
}

/* Hands one written entry to the caller's callback, if there is one. */
static int report_entry(zip_entry_fn entry_cb, void *entry_user, const char *name, const char *path,
                        int is_dir, uint64_t size, uint32_t crc, uint16_t dos_date, uint16_t dos_time) {
  zip_entry_info info = { name, path, is_dir, size, crc, dos_date, dos_time };
  return entry_cb ? entry_cb(&info, entry_user) : 0;
}

int zip_extract_all_ex(zip_reader *z, const char *destdir,
                       zip_progress cb, void *user,
                       zip_entry_fn entry_cb, void *entry_user,
                       size_t *skipped, char *err, size_t errlen) {
  size_t i;
  size_t skip_count = 0;

  struct zip_io_buf *io;

  if (skipped) *skipped = 0;
  if (!z) { fail(err, errlen, "no archive"); return -1; }
  if (make_dirs(destdir) != 0) { fail(err, errlen, "cannot create destination"); return -1; }
  /* Half a megabyte, once, off the stack. See the CHUNK comment. */
  if (!(io = malloc(sizeof(*io)))) { fail(err, errlen, "out of memory"); return -1; }

  for (i = 0; i < z->count; i++) {
    zip_entry *e = &z->entries[i];
    char safe[MAX_NAME], full[MAX_NAME];
    uint64_t data_off;
    uint32_t crc = (uint32_t)crc32(0, NULL, 0);
    FILE *outf;

    if (zip_safe_path(e->name, safe, sizeof(safe)) != 0) { skip_count++; continue; }

    if (((e->external_attrs >> 16) & 0xf000) == 0xa000) { skip_count++; continue; }
    if (e->flags & FLAG_ENCRYPTED) { skip_count++; continue; }
    if (e->method != METHOD_STORE && e->method != METHOD_DEFLATE) { skip_count++; continue; }

    if ((size_t)snprintf(full, sizeof(full), "%s/%s", destdir, safe) >= sizeof(full)) {
      skip_count++;
      continue;
    }

    if (e->is_dir) {
      if (make_dirs(full) != 0) { skip_count++; continue; }
      if (report_entry(entry_cb, entry_user, e->name, full, 1, 0, 0, e->dos_date, e->dos_time) != 0) {
        fail(err, errlen, "cancelled");
        free(io);
        return -1;
      }
      continue;
    }
    if (make_parent_dirs(full) != 0) { skip_count++; continue; }
    if (local_data_offset(z->f, e, &data_off) != 0) { skip_count++; continue; }
    if (fseeko(z->f, (off_t)data_off, SEEK_SET) != 0) { skip_count++; continue; }

    if (!(outf = fopen(full, "wb"))) { skip_count++; continue; }
    {
      int rc = (e->method == METHOD_STORE)
                   ? write_stored(file_read, z->f, outf, e->comp_size, &crc, io)
                   : write_deflated(file_read, z->f, outf, e->comp_size, &crc, io);

      fclose(outf);
      if (rc != 0 || crc != e->crc) {
        remove(full);
        skip_count++;
        continue;
      }
    }
    /* Executable bit for anything the archive marked executable; harmless on
     * the Windows side and needed if the file is ever run through the host. */
    if (((e->external_attrs >> 16) & 0111) != 0) chmod(full, 0755);

    if (report_entry(entry_cb, entry_user, e->name, full, 0, e->size, e->crc, e->dos_date, e->dos_time) != 0 ||
        (cb && cb(safe, (uint64_t)i + 1, (uint64_t)z->count, user) != 0)) {
      fail(err, errlen, "cancelled");
      free(io);
      return -1;
    }
  }

  free(io);
  if (skipped) *skipped = skip_count;
  return 0;
}

int zip_extract_stream(zip_read_fn read, void *ctx, const char *destdir,
                       char *err, size_t errlen) {
  return zip_extract_stream_ex(read, ctx, destdir, NULL, NULL, err, errlen);
}

int zip_extract_stream_ex(zip_read_fn read, void *ctx, const char *destdir,
                          zip_entry_fn entry_cb, void *entry_user,
                          char *err, size_t errlen) {
  struct zip_io_buf *io;
  int rc = -1;

  if (make_dirs(destdir) != 0) { fail(err, errlen, "cannot create destination"); return -1; }
  if (!(io = malloc(sizeof(*io)))) { fail(err, errlen, "out of memory"); return -1; }

  for (;;) {
    unsigned char hdr[30];
    char name[MAX_NAME], safe[MAX_NAME], full[MAX_NAME];
    uint32_t sig, crc = (uint32_t)crc32(0, NULL, 0);
    uint64_t comp_size, size;
    uint16_t flags, method, name_len, extra_len;
    FILE *outf;
    int wrc;

    if (read(ctx, hdr, 4) != 0) { fail(err, errlen, "truncated archive"); goto done; }
    sig = rd32(hdr);
    if (sig == SIG_CENTRAL || sig == SIG_EOCD) break;
    if (sig != SIG_LOCAL) { fail(err, errlen, "not a zip archive"); goto done; }
    if (read(ctx, hdr + 4, 26) != 0) { fail(err, errlen, "truncated archive"); goto done; }
    flags = rd16(hdr + 6);
    method = rd16(hdr + 8);
    comp_size = rd32(hdr + 18);
    size = rd32(hdr + 22);
    name_len = rd16(hdr + 26);
    extra_len = rd16(hdr + 28);
    /* A data descriptor leaves the sizes out of the local header, and a zip64
     * entry keeps them in an extra field; neither can be read in one pass. */
    if ((flags & (FLAG_ENCRYPTED | FLAG_DATA_DESCRIPTOR)) || comp_size == 0xffffffffu || size == 0xffffffffu ||
        (method != METHOD_STORE && method != METHOD_DEFLATE) ||
        (method == METHOD_STORE && comp_size != size)) {
      fail(err, errlen, "unsupported zip entry");
      goto done;
    }
    if (!name_len || name_len >= sizeof(name) || read(ctx, name, name_len) != 0 ||
        read(ctx, NULL, extra_len) != 0) {
      fail(err, errlen, "truncated archive");
      goto done;
    }
    name[name_len] = '\0';
    if (zip_safe_path(name, safe, sizeof(safe)) != 0 ||
        (size_t)snprintf(full, sizeof(full), "%s/%s", destdir, safe) >= sizeof(full)) {
      if (err && errlen) snprintf(err, errlen, "unsafe entry name: %s", name);
      goto done;
    }
    if (name[name_len - 1] == '/' || name[name_len - 1] == '\\') {
      if (comp_size || make_dirs(full) != 0) { fail(err, errlen, "cannot create a folder"); goto done; }
      if (report_entry(entry_cb, entry_user, name, full, 1, 0, 0, rd16(hdr + 12), rd16(hdr + 10)) != 0) {
        fail(err, errlen, "cancelled");
        goto done;
      }
      continue;
    }
    if (make_parent_dirs(full) != 0 || !(outf = fopen(full, "wb"))) {
      fail(err, errlen, "cannot create a file");
      goto done;
    }
    wrc = method == METHOD_STORE ? write_stored(read, ctx, outf, comp_size, &crc, io)
                                 : write_deflated(read, ctx, outf, comp_size, &crc, io);
    if (fclose(outf) != 0) wrc = -1;
    if (wrc != 0 || crc != rd32(hdr + 14)) {
      remove(full);
      if (err && errlen) snprintf(err, errlen, "damaged entry: %s", safe);
      goto done;
    }
    if (report_entry(entry_cb, entry_user, name, full, 0, size, crc, rd16(hdr + 12), rd16(hdr + 10)) != 0) {
      fail(err, errlen, "cancelled");
      goto done;
    }
  }
  rc = 0;
done:
  free(io);
  return rc;
}

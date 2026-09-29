#include "vz.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#include "zip.h"
#include "../lzma/LzmaDec.h"

/* A package is "VZa", a 4-byte timestamp and the LZMA properties, then raw
 * LZMA data, then the CRC-32 and size of the decoded data and "zv". */
#define VZ_HEADER (7 + LZMA_PROPS_SIZE)
#define VZ_FOOTER 10

#define IN_CHUNK  (64 * 1024)
#define OUT_CHUNK (1024 * 1024)

struct vz_stream {
  FILE *f;
  uint64_t packed_left;
  CLzmaDec dec;
  Byte in[IN_CHUNK];
  size_t in_pos, in_len;
  Byte *out;
  size_t out_pos, out_len;
  uint64_t decoded, size;
  uint32_t crc;
  vz_progress cb;
  void *user;
  const char *failure;
};

static uint32_t rd32(const unsigned char *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void *lzma_alloc(ISzAllocPtr p, size_t size) { (void)p; return malloc(size); }
static void lzma_free(ISzAllocPtr p, void *address) { (void)p; free(address); }
static const ISzAlloc lzma_allocator = { lzma_alloc, lzma_free };

/* Decodes the next piece of data into out. */
static int fill(struct vz_stream *s) {
  uint64_t want = s->size - s->decoded;

  if (!want) { s->failure = "the package is truncated"; return -1; }
  if (want > OUT_CHUNK) want = OUT_CHUNK;
  s->out_pos = s->out_len = 0;
  while (!s->out_len) {
    SizeT out_len = (SizeT)want, in_len;
    ELzmaStatus status;

    if (s->in_pos == s->in_len && s->packed_left) {
      size_t n = s->packed_left < IN_CHUNK ? (size_t)s->packed_left : IN_CHUNK;

      if (fread(s->in, 1, n, s->f) != n) { s->failure = "cannot read the package"; return -1; }
      s->packed_left -= n;
      s->in_pos = 0;
      s->in_len = n;
    }
    in_len = s->in_len - s->in_pos;
    if (LzmaDec_DecodeToBuf(&s->dec, s->out, &out_len, s->in + s->in_pos, &in_len,
                            LZMA_FINISH_ANY, &status) != SZ_OK ||
        (!out_len && !in_len)) {
      s->failure = "the package is damaged";
      return -1;
    }
    s->in_pos += in_len;
    s->out_len = out_len;
  }
  s->crc = (uint32_t)crc32(s->crc, s->out, (uInt)s->out_len);
  s->decoded += s->out_len;
  if (s->cb && s->cb(s->decoded, s->size, s->user)) { s->failure = "cancelled"; return -1; }
  return 0;
}

static int stream_read(void *ctx, void *buf, size_t len) {
  struct vz_stream *s = ctx;

  while (len) {
    size_t n;

    if (s->out_pos == s->out_len && fill(s)) return -1;
    n = s->out_len - s->out_pos;
    if (n > len) n = len;
    if (buf) {
      memcpy(buf, s->out + s->out_pos, n);
      buf = (char *)buf + n;
    }
    s->out_pos += n;
    len -= n;
  }
  return 0;
}

int vz_extract(const char *path, const char *destdir, vz_progress cb, void *user,
               char *err, size_t errlen) {
  return vz_extract_ex(path, destdir, cb, user, NULL, NULL, err, errlen);
}

int vz_extract_ex(const char *path, const char *destdir, vz_progress cb, void *user,
                  zip_entry_fn entry_cb, void *entry_user, char *err, size_t errlen) {
  unsigned char head[VZ_HEADER], foot[VZ_FOOTER], *props = head + 7;
  struct vz_stream *s;
  uint32_t dict;
  off_t total;
  int rc = -1;

  if (!(s = calloc(1, sizeof(*s)))) { snprintf(err, errlen, "out of memory"); return -1; }
  LzmaDec_Construct(&s->dec);
  s->cb = cb;
  s->user = user;
  s->crc = (uint32_t)crc32(0, NULL, 0);
  if (!(s->f = fopen(path, "rb"))) { snprintf(err, errlen, "cannot open the package"); goto out; }
  if (fseeko(s->f, 0, SEEK_END) != 0 || (total = ftello(s->f)) < VZ_HEADER + VZ_FOOTER ||
      fseeko(s->f, total - VZ_FOOTER, SEEK_SET) != 0 || fread(foot, 1, VZ_FOOTER, s->f) != VZ_FOOTER ||
      fseeko(s->f, 0, SEEK_SET) != 0 || fread(head, 1, VZ_HEADER, s->f) != VZ_HEADER ||
      memcmp(head, "VZa", 3) != 0 || memcmp(foot + 8, "zv", 2) != 0) {
    snprintf(err, errlen, "not a VZ package");
    goto out;
  }
  s->size = rd32(foot + 4);
  s->packed_left = (uint64_t)total - VZ_HEADER - VZ_FOOTER;
  /* Matches never reach back past the start of the data, so the dictionary
   * needs to be no larger than the data: small packages decode in kilobytes. */
  dict = rd32(props + 1);
  if (dict > s->size) {
    dict = (uint32_t)s->size;
    props[1] = (unsigned char)dict;
    props[2] = (unsigned char)(dict >> 8);
    props[3] = (unsigned char)(dict >> 16);
    props[4] = (unsigned char)(dict >> 24);
  }
  if (LzmaDec_Allocate(&s->dec, props, LZMA_PROPS_SIZE, &lzma_allocator) != SZ_OK ||
      !(s->out = malloc(OUT_CHUNK))) {
    snprintf(err, errlen, "not a VZ package, or out of memory");
    goto out;
  }
  LzmaDec_Init(&s->dec);
  if (zip_extract_stream_ex(stream_read, s, destdir, entry_cb, entry_user, err, errlen) != 0) {
    if (s->failure) snprintf(err, errlen, "%s", s->failure);
    goto out;
  }
  /* The central directory is the rest; it counts towards the CRC. */
  while (s->decoded < s->size)
    if (fill(s)) { snprintf(err, errlen, "%s", s->failure); goto out; }
  if (s->crc != rd32(foot)) { snprintf(err, errlen, "the package is damaged"); goto out; }
  rc = 0;
out:
  if (s->f) fclose(s->f);
  LzmaDec_Free(&s->dec, &lzma_allocator);
  free(s->out);
  free(s);
  return rc;
}

#include "pe_icon.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { RT_ICON = 3, RT_GROUP_ICON = 14 };
#define MAX_SECTION (64u << 20)
#define DIR_BIT 0x80000000u          /* OffsetToData: a subdirectory */
#define NAME_IS_STRING 0x80000000u   /* Name: a string, not an id */

static uint16_t rd16(const unsigned char *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t rd32(const unsigned char *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static void wr16(unsigned char *p, uint16_t v) { p[0] = (unsigned char)v; p[1] = (unsigned char)(v >> 8); }
static void wr32(unsigned char *p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = (unsigned char)(v >> (8 * i)); }

static int read_at(FILE *f, long off, void *buf, size_t len) {
  return fseek(f, off, SEEK_SET) == 0 && fread(buf, 1, len, f) == len ? 0 : -1;
}

/* The resource section, loaded whole, and where it sits in the image. */
typedef struct {
  unsigned char *data;
  uint32_t rva, size;   /* of the loaded bytes */
  uint32_t root;        /* offset of the resource root within data */
} rsrc;

static const unsigned char *at(const rsrc *r, uint32_t off, uint32_t len) {
  return off <= r->size && len <= r->size - off ? r->data + off : NULL;
}

/* Entry `want_id` (or the first entry when want_id is 0) of the directory at
 * dir_off; returns its OffsetToData, or 0 when absent. */
static uint32_t dir_entry(const rsrc *r, uint32_t dir_off, uint32_t want_id) {
  const unsigned char *d = at(r, r->root + dir_off, 16);
  if (!d) return 0;
  uint32_t named = rd16(d + 12), ids = rd16(d + 14);
  if (named + ids > 4096) return 0;
  const unsigned char *e = at(r, r->root + dir_off + 16, (named + ids) * 8);
  if (!e) return 0;
  for (uint32_t i = 0; i < named + ids; i++) {
    uint32_t name = rd32(e + i * 8), target = rd32(e + i * 8 + 4);
    if (!want_id || (!(name & NAME_IS_STRING) && name == want_id)) return target;
  }
  return 0;
}

/* Walks type/id/language down to a data entry and returns the resource bytes. */
static const unsigned char *resource(const rsrc *r, uint32_t type, uint32_t id, uint32_t *len) {
  uint32_t level = dir_entry(r, 0, type);
  if (!(level & DIR_BIT)) return NULL;
  level = dir_entry(r, level & ~DIR_BIT, id);
  if (!(level & DIR_BIT)) return NULL;
  uint32_t leaf = dir_entry(r, level & ~DIR_BIT, 0);
  if (!leaf || (leaf & DIR_BIT)) return NULL;
  const unsigned char *entry = at(r, r->root + leaf, 16);
  if (!entry) return NULL;
  uint32_t data_rva = rd32(entry), size = rd32(entry + 4);
  if (data_rva < r->rva) return NULL;
  *len = size;
  return at(r, data_rva - r->rva, size);
}

static int load_rsrc(FILE *f, rsrc *r) {
  unsigned char b[64];
  if (read_at(f, 0, b, 64) || b[0] != 'M' || b[1] != 'Z') return -1;
  uint32_t pe = rd32(b + 0x3c);
  if (pe < 0x40 || pe > (1u << 30) || read_at(f, pe, b, 24) || memcmp(b, "PE\0\0", 4)) return -1;
  uint16_t sections = rd16(b + 6), opt_size = rd16(b + 20);
  uint32_t opt = pe + 24;
  if (read_at(f, opt, b, 2)) return -1;
  uint16_t magic = rd16(b);
  uint32_t dirs = magic == 0x20b ? 112 : magic == 0x10b ? 96 : 0;
  if (!dirs || opt_size < dirs + 3 * 8 || read_at(f, opt + dirs - 4, b, 4 + 3 * 8)) return -1;
  if (rd32(b) < 3) return -1;
  uint32_t res_rva = rd32(b + 4 + 2 * 8);
  if (!res_rva) return -1;
  for (uint16_t i = 0; i < sections && i < 96; i++) {
    if (read_at(f, opt + opt_size + i * 40u, b, 40)) return -1;
    uint32_t vsize = rd32(b + 8), va = rd32(b + 12), raw = rd32(b + 16), ptr = rd32(b + 20);
    uint32_t span = vsize > raw ? raw : vsize ? vsize : raw;
    if (res_rva < va || res_rva - va >= span) continue;
    if (span > MAX_SECTION || !(r->data = malloc(span))) return -1;
    if (read_at(f, ptr, r->data, span)) { free(r->data); r->data = NULL; return -1; }
    r->rva = va;
    r->size = span;
    r->root = res_rva - va;
    return 0;
  }
  return -1;
}

int pe_icon_extract(const char *path, unsigned char **out, size_t *out_len) {
  FILE *f = fopen(path, "rb");
  rsrc r = { 0 };
  int rc = -1;
  if (!f) return -1;
  if (load_rsrc(f, &r)) goto done;

  uint32_t group_len = 0;
  const unsigned char *group = resource(&r, RT_GROUP_ICON, 0, &group_len);
  if (!group || group_len < 6 || rd16(group + 2) != 1) goto done;
  uint16_t count = rd16(group + 4);
  if (group_len < 6u + count * 14u) goto done;

  const unsigned char *best = NULL;
  unsigned best_px = 0, best_bits = 0;
  for (uint16_t i = 0; i < count; i++) {
    const unsigned char *e = group + 6 + i * 14;
    unsigned px = e[0] ? e[0] : 256, bits = rd16(e + 6);
    if (px > best_px || (px == best_px && bits > best_bits)) { best = e; best_px = px; best_bits = bits; }
  }
  if (!best) goto done;

  uint32_t len = 0;
  const unsigned char *img = resource(&r, RT_ICON, rd16(best + 12), &len);
  if (!img || len < 8) goto done;
  if (!memcmp(img, "\x89PNG\r\n\x1a\n", 8)) {
    if (!(*out = malloc(len))) goto done;
    memcpy(*out, img, len);
    *out_len = len;
  } else {
    if (!(*out = malloc(22u + len))) goto done;
    unsigned char *ico = *out;
    wr16(ico, 0); wr16(ico + 2, 1); wr16(ico + 4, 1);
    memcpy(ico + 6, best, 8);             /* width, height, colours, reserved, planes, bit count */
    wr32(ico + 14, len);
    wr32(ico + 18, 22);
    memcpy(ico + 22, img, len);
    *out_len = 22u + len;
  }
  rc = 0;
done:
  free(r.data);
  fclose(f);
  return rc;
}

#ifndef IOS_ZIP_H
#define IOS_ZIP_H

#include <stddef.h>
#include <stdint.h>

typedef struct zip_reader zip_reader;

/* Called once per entry as it is written. Return non-zero to abort. */
typedef int (*zip_progress)(const char *name, uint64_t done, uint64_t total,
                            void *user);

int  zip_open(const char *path, zip_reader **out, char *err, size_t errlen);
void zip_close(zip_reader *z);

size_t      zip_count(const zip_reader *z);
const char *zip_entry_name(const zip_reader *z, size_t i);
int         zip_entry_is_dir(const zip_reader *z, size_t i);
uint64_t    zip_entry_size(const zip_reader *z, size_t i);

int zip_extract_all(zip_reader *z, const char *destdir,
                    zip_progress cb, void *user,
                    size_t *skipped, char *err, size_t errlen);

/* An entry as it lands on disk: its name in the archive, the path it was
 * written to, its size and CRC-32, and its MS-DOS modification date and time. */
typedef struct {
  const char *name;
  const char *path;
  int         is_dir;
  uint64_t    size;
  uint32_t    crc;
  uint16_t    dos_date, dos_time;
} zip_entry_info;

/* Called after each entry is written; non-zero aborts the extraction. */
typedef int (*zip_entry_fn)(const zip_entry_info *entry, void *user);

/* zip_extract_all, also reporting every entry it writes to entry_cb. */
int zip_extract_all_ex(zip_reader *z, const char *destdir,
                       zip_progress cb, void *user,
                       zip_entry_fn entry_cb, void *entry_user,
                       size_t *skipped, char *err, size_t errlen);

/* Reads exactly len bytes into buf, or skips them when buf is NULL. 0 on
 * success. */
typedef int (*zip_read_fn)(void *ctx, void *buf, size_t len);

/* Extracts an archive read front to back, as a stream delivers it: each local
 * entry up to the central directory. Stored and deflated entries whose local
 * header carries their sizes; anything else, an unsafe name or a bad CRC is
 * an error rather than a skip. */
int zip_extract_stream(zip_read_fn read, void *ctx, const char *destdir,
                       char *err, size_t errlen);

/* zip_extract_stream, also reporting every entry it writes to entry_cb. */
int zip_extract_stream_ex(zip_read_fn read, void *ctx, const char *destdir,
                          zip_entry_fn entry_cb, void *entry_user,
                          char *err, size_t errlen);

int zip_safe_path(const char *name, char *out, size_t outlen);

#endif

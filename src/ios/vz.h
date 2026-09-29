/* Valve's VZ packages: the LZMA-compressed zips Steam's client updates ship
 * in. */
#ifndef IOSWINE_VZ_H
#define IOSWINE_VZ_H

#include <stddef.h>
#include <stdint.h>

#include "zip.h"

/* Bytes decoded so far and in all. Return non-zero to stop. */
typedef int (*vz_progress)(uint64_t done, uint64_t total, void *user);

/* Extracts the zip inside a VZ package into destdir as it decodes, so the zip
 * never lands on disk, and checks the decoded data against the package's
 * CRC-32. 0, or -1 with a reason in err ("cancelled" when cb stopped it). */
int vz_extract(const char *path, const char *destdir, vz_progress cb, void *user,
               char *err, size_t errlen);

/* vz_extract, also reporting every entry of the zip it writes to entry_cb
 * (see zip.h). */
int vz_extract_ex(const char *path, const char *destdir, vz_progress cb, void *user,
                  zip_entry_fn entry_cb, void *entry_user, char *err, size_t errlen);

#endif

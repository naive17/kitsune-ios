#ifndef IOS_PE_ICON_H
#define IOS_PE_ICON_H

#include <stddef.h>

/* The largest image of the first icon group in a PE file's resources, as PNG
 * bytes when the image is PNG and otherwise as a one-image .ico file. Returns 0
 * and a malloc'd buffer, or -1 when the file has no usable icon. */
int pe_icon_extract(const char *path, unsigned char **out, size_t *out_len);

#endif

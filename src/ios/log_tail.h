#pragma once
#import <Foundation/Foundation.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

/* Diagnostic previews must have bounded memory even after a runaway trace.
 * Keep the full file on disk; tolerate a tail starting inside a UTF-8 codepoint. */
static inline NSString *KitsuneLogTail(NSString *path, NSUInteger limit) {
    if (!limit) return @"";
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NONBLOCK);
    if (fd < 0) return @"";
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_size <= 0) {
        close(fd); return @"";
    }
    NSUInteger length = (NSUInteger)MIN((uint64_t)st.st_size, (uint64_t)limit);
    off_t offset = st.st_size - (off_t)length;
    NSMutableData *data = [NSMutableData dataWithLength:length];
    NSUInteger used = 0;
    while (used < length) {
        ssize_t got = pread(fd, (char *)data.mutableBytes + used, length - used, offset + used);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) break;
        used += (NSUInteger)got;
    }
    close(fd);
    data.length = used;
    NSUInteger skip = 0;
    const unsigned char *bytes = data.bytes;
    if (offset) while (skip < used && (bytes[skip] & 0xc0) == 0x80) ++skip;
    if (skip) [data replaceBytesInRange:NSMakeRange(0, skip) withBytes:NULL length:0];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?:
           [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] ?: @"";
}

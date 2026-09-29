#import "../src/ios/log_tail.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    @autoreleasepool {
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"ioswine-tail-test-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        assert([IOSWineLogTail(path, 128) isEqualToString:@""]);
        assert([@"small log\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]);
        assert([IOSWineLogTail(path, 128) isEqualToString:@"small log\n"]);
        assert([IOSWineLogTail(path, 0) isEqualToString:@""]);
        assert([@"x€END" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]);
        assert([IOSWineLogTail(path, 4) isEqualToString:@"END"]);
        unsigned char invalid[] = {0xff, 'X'};
        assert([[NSData dataWithBytes:invalid length:sizeof(invalid)] writeToFile:path atomically:YES]);
        assert([IOSWineLogTail(path, 10) hasSuffix:@"X"]);
        int fd = open(path.fileSystemRepresentation, O_RDWR | O_TRUNC);
        assert(fd >= 0);
        assert(ftruncate(fd, 800ll * 1024 * 1024) == 0); /* sparse runaway-log fixture */
        assert(pwrite(fd, "LATEST\n", 7, 800ll * 1024 * 1024 - 7) == 7);
        close(fd);
        NSString *tail = IOSWineLogTail(path, 128 * 1024);
        assert(tail.length == 128 * 1024 && [tail hasSuffix:@"LATEST\n"]);
        struct stat st;
        assert(stat(path.fileSystemRepresentation, &st) == 0 && st.st_size == 800ll * 1024 * 1024);
        assert([NSFileManager.defaultManager removeItemAtPath:path error:nil]);
        puts("PASS: bounded log tail, sparse 800MB input preserved, UTF-8 boundary, invalid bytes, missing/zero limit");
    }
}

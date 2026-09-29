#import "../src/ios/launch_request.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
  @autoreleasepool {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = [[NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"ioswine-launch-" stringByAppendingString:NSUUID.UUID.UUIDString]] stringByResolvingSymlinksInPath];
    NSString *apps = [root stringByAppendingPathComponent:@"Apps/Steam"];
    assert([fm createDirectoryAtPath:apps withIntermediateDirectories:YES attributes:nil error:nil]);
    assert([@"test" writeToFile:[apps stringByAppendingPathComponent:@"steam.exe"]
        atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    NSMutableDictionary *request = [@{@"exe": @"Apps/Steam/steam.exe", @"bottle": @"Steam",
        @"args": @[@"-no-cef-sandbox", @"a b", @"$literal"]} mutableCopy];
    NSString *error = nil;
    NSDictionary *valid = IOSWineValidateLaunchRequest(request, root, &error);
    assert(valid && !error && [valid[@"args"] isEqual:request[@"args"]]);
    assert([valid[@"exe"] isEqual:[apps stringByAppendingPathComponent:@"steam.exe"]]);
    for (id bad in @[@"", @"../prefix", @"/prefix", @"Steam/other", @42]) {
      request[@"bottle"] = bad;
      assert(!IOSWineValidateLaunchRequest(request, root, &error) && error);
    }
    request[@"bottle"] = @"Steam";
    for (id bad in @[@"/Apps/Steam/steam.exe", @"Apps/../prefix", @"Apps//steam.exe",
        @"Apps/./Steam/steam.exe", @"Apps/Steam/missing.exe", @"Apps/Steam", @42]) {
      request[@"exe"] = bad;
      assert(!IOSWineValidateLaunchRequest(request, root, &error));
    }
    request[@"exe"] = @"Apps/Steam/steam.exe";
    request[@"args"] = @[@42];
    assert(!IOSWineValidateLaunchRequest(request, root, &error));
    request[@"args"] = @[[NSString stringWithFormat:@"a%Cb", (unichar)0]];
    assert(!IOSWineValidateLaunchRequest(request, root, &error));
    request[@"args"] = @[];
    assert(IOSWineValidateLaunchRequest(request, root, &error));
    assert([fm createSymbolicLinkAtPath:[root stringByAppendingPathComponent:@"Bottles"]
        withDestinationPath:apps error:nil]);
    assert(!IOSWineValidateLaunchRequest(request, root, &error));
    assert([fm removeItemAtPath:root error:nil]);
    puts("PASS: launch request parsing, literal args, traversal, missing files, types, NUL and bottle symlink rejection");
  }
}

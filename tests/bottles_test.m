#import "../src/ios/bottles.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
  @autoreleasepool {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"bottles-test-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *docs = [base stringByAppendingPathComponent:@"Documents"];
    NSString *tree = [base stringByAppendingPathComponent:@"tree"];
    NSString *error = nil;
    assert([fm createDirectoryAtPath:[tree stringByAppendingPathComponent:@"prefix-template/drive_c"] withIntermediateDirectories:YES attributes:nil error:nil]);
    assert([fm createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:nil]);
    assert(KitsuneBottleNames(docs).count == 0);
    assert(!KitsuneCreateBottle(docs, tree, @"games", &error) && [error containsString:@"template"]);
    assert([@"REGEDIT4" writeToFile:[tree stringByAppendingPathComponent:@"prefix-template/system.reg"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    assert([@"abc123" writeToFile:[tree stringByAppendingPathComponent:@"TREE_VERSION"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    assert(!KitsuneCreateBottle(docs, tree, @"bad name!", &error));
    assert(!KitsuneCreateBottle(docs, tree, @"default", &error));
    assert(!KitsuneCreateBottle(docs, tree, @"../escape", &error));
    assert(KitsuneCreateBottle(docs, tree, @"games", &error) && !error);
    assert(!KitsuneCreateBottle(docs, tree, @"games", &error) && [error containsString:@"already"]);
    NSString *path = KitsuneBottlePath(docs, @"games");
    assert([path hasSuffix:@"Documents/Bottles/games"]);
    assert([fm fileExistsAtPath:[path stringByAppendingPathComponent:@"system.reg"]]);
    assert([[fm destinationOfSymbolicLinkAtPath:[path stringByAppendingPathComponent:@"dosdevices/c:"] error:nil] isEqualToString:@"../drive_c"]);
    assert([[NSString stringWithContentsOfFile:[path stringByAppendingPathComponent:@".tree-stamp"] encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"abc123"]);
    assert([fm createDirectoryAtPath:[docs stringByAppendingPathComponent:@"Bottles/Steam"] withIntermediateDirectories:YES attributes:nil error:nil]);
    assert([@"REGEDIT4" writeToFile:[docs stringByAppendingPathComponent:@"Bottles/Steam/system.reg"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    assert([fm createDirectoryAtPath:[docs stringByAppendingPathComponent:@"Bottles/broken"] withIntermediateDirectories:YES attributes:nil error:nil]);
    assert([fm createDirectoryAtPath:[docs stringByAppendingPathComponent:@"prefix"] withIntermediateDirectories:YES attributes:nil error:nil]);
    assert([@"REGEDIT4" writeToFile:[docs stringByAppendingPathComponent:@"prefix/system.reg"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    NSArray *names = KitsuneBottleNames(docs);
    assert(([names isEqual:@[ @"default", @"games", @"Steam" ]]));
    assert([KitsuneBottlePath(docs, @"default") hasSuffix:@"Documents/prefix"] && [KitsuneBottlePath(docs, nil) hasSuffix:@"Documents/prefix"]);
    assert(!KitsuneDeleteBottle(docs, @"Steam", &error) && !KitsuneDeleteBottle(docs, @"default", &error));
    assert(KitsuneDeleteBottle(docs, @"games", &error) && !error);
    assert(!KitsuneDeleteBottle(docs, @"games", &error));
    assert(([KitsuneBottleNames(docs) isEqual:@[ @"default", @"Steam" ]]));
    assert([fm removeItemAtPath:[docs stringByAppendingPathComponent:@"prefix"] error:nil]);
    assert(KitsuneCreateDefaultPrefix(docs, tree, &error) && !error);
    assert([fm fileExistsAtPath:[docs stringByAppendingPathComponent:@"prefix/system.reg"]]);
    assert([[fm destinationOfSymbolicLinkAtPath:[docs stringByAppendingPathComponent:@"prefix/dosdevices/c:"] error:nil] isEqualToString:@"../drive_c"]);
    assert(KitsuneCreateDefaultPrefix(docs, tree, &error));   /* idempotent */
    assert(([KitsuneBottleNames(docs) isEqual:@[ @"default", @"Steam" ]]));
    assert(KitsuneCreateBottle(docs, tree, @"games", &error));
    assert(!KitsuneRenameBottle(docs, @"default", @"other", &error) && !KitsuneRenameBottle(docs, @"Steam", @"other", &error));
    assert(!KitsuneRenameBottle(docs, @"games", @"Steam", &error) && !KitsuneRenameBottle(docs, @"games", @"default", &error));
    assert(!KitsuneRenameBottle(docs, @"games", @"bad name", &error));
    assert(KitsuneRenameBottle(docs, @"games", @"arcade", &error) && !error);
    assert(![fm fileExistsAtPath:KitsuneBottlePath(docs, @"games")]);
    assert([[fm destinationOfSymbolicLinkAtPath:[KitsuneBottlePath(docs, @"arcade") stringByAppendingPathComponent:@"dosdevices/c:"] error:nil] isEqualToString:@"../drive_c"]);
    assert(!KitsuneRenameBottle(docs, @"arcade", @"Steam", &error));
    assert(KitsuneDuplicateBottle(docs, @"default", @"copy", &error) && !error);
    assert([fm fileExistsAtPath:[KitsuneBottlePath(docs, @"copy") stringByAppendingPathComponent:@"system.reg"]]);
    assert([[fm destinationOfSymbolicLinkAtPath:[KitsuneBottlePath(docs, @"copy") stringByAppendingPathComponent:@"dosdevices/c:"] error:nil] isEqualToString:@"../drive_c"]);
    assert([fm fileExistsAtPath:[docs stringByAppendingPathComponent:@"prefix/system.reg"]]);
    assert(!KitsuneDuplicateBottle(docs, @"arcade", @"copy", &error) && [error containsString:@"already"]);
    assert(!KitsuneDuplicateBottle(docs, @"missing", @"copy2", &error) && [error containsString:@"no bottle"]);
    assert(KitsuneDuplicateBottle(docs, @"Steam", @"steam-copy", &error));
    assert(([KitsuneBottleNames(docs) isEqual:@[ @"default", @"arcade", @"copy", @"Steam", @"steam-copy" ]]));
    assert([fm removeItemAtPath:base error:nil]);
    puts("BOTTLES PASS: names validated, template copy with drive links and stamp, listing, protected bottles, rename, duplicate");
  }
}

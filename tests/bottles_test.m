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
    assert(IOSWineBottleNames(docs).count == 0);
    assert(!IOSWineCreateBottle(docs, tree, @"games", &error) && [error containsString:@"template"]);
    assert([@"REGEDIT4" writeToFile:[tree stringByAppendingPathComponent:@"prefix-template/system.reg"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    assert([@"abc123" writeToFile:[tree stringByAppendingPathComponent:@"TREE_VERSION"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    assert(!IOSWineCreateBottle(docs, tree, @"bad name!", &error));
    assert(!IOSWineCreateBottle(docs, tree, @"default", &error));
    assert(!IOSWineCreateBottle(docs, tree, @"../escape", &error));
    assert(IOSWineCreateBottle(docs, tree, @"games", &error) && !error);
    assert(!IOSWineCreateBottle(docs, tree, @"games", &error) && [error containsString:@"already"]);
    NSString *path = IOSWineBottlePath(docs, @"games");
    assert([path hasSuffix:@"Documents/Bottles/games"]);
    assert([fm fileExistsAtPath:[path stringByAppendingPathComponent:@"system.reg"]]);
    assert([[fm destinationOfSymbolicLinkAtPath:[path stringByAppendingPathComponent:@"dosdevices/c:"] error:nil] isEqualToString:@"../drive_c"]);
    assert([[NSString stringWithContentsOfFile:[path stringByAppendingPathComponent:@".tree-stamp"] encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"abc123"]);
    assert([fm createDirectoryAtPath:[docs stringByAppendingPathComponent:@"Bottles/Steam"] withIntermediateDirectories:YES attributes:nil error:nil]);
    assert([@"REGEDIT4" writeToFile:[docs stringByAppendingPathComponent:@"Bottles/Steam/system.reg"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    assert([fm createDirectoryAtPath:[docs stringByAppendingPathComponent:@"Bottles/broken"] withIntermediateDirectories:YES attributes:nil error:nil]);
    assert([fm createDirectoryAtPath:[docs stringByAppendingPathComponent:@"prefix"] withIntermediateDirectories:YES attributes:nil error:nil]);
    assert([@"REGEDIT4" writeToFile:[docs stringByAppendingPathComponent:@"prefix/system.reg"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    NSArray *names = IOSWineBottleNames(docs);
    assert(([names isEqual:@[ @"default", @"games", @"Steam" ]]));
    assert([IOSWineBottlePath(docs, @"default") hasSuffix:@"Documents/prefix"] && [IOSWineBottlePath(docs, nil) hasSuffix:@"Documents/prefix"]);
    assert(!IOSWineDeleteBottle(docs, @"Steam", &error) && !IOSWineDeleteBottle(docs, @"default", &error));
    assert(IOSWineDeleteBottle(docs, @"games", &error) && !error);
    assert(!IOSWineDeleteBottle(docs, @"games", &error));
    assert(([IOSWineBottleNames(docs) isEqual:@[ @"default", @"Steam" ]]));
    assert([fm removeItemAtPath:[docs stringByAppendingPathComponent:@"prefix"] error:nil]);
    assert(IOSWineCreateDefaultPrefix(docs, tree, &error) && !error);
    assert([fm fileExistsAtPath:[docs stringByAppendingPathComponent:@"prefix/system.reg"]]);
    assert([[fm destinationOfSymbolicLinkAtPath:[docs stringByAppendingPathComponent:@"prefix/dosdevices/c:"] error:nil] isEqualToString:@"../drive_c"]);
    assert(IOSWineCreateDefaultPrefix(docs, tree, &error));   /* idempotent */
    assert(([IOSWineBottleNames(docs) isEqual:@[ @"default", @"Steam" ]]));
    assert(IOSWineCreateBottle(docs, tree, @"games", &error));
    assert(!IOSWineRenameBottle(docs, @"default", @"other", &error) && !IOSWineRenameBottle(docs, @"Steam", @"other", &error));
    assert(!IOSWineRenameBottle(docs, @"games", @"Steam", &error) && !IOSWineRenameBottle(docs, @"games", @"default", &error));
    assert(!IOSWineRenameBottle(docs, @"games", @"bad name", &error));
    assert(IOSWineRenameBottle(docs, @"games", @"arcade", &error) && !error);
    assert(![fm fileExistsAtPath:IOSWineBottlePath(docs, @"games")]);
    assert([[fm destinationOfSymbolicLinkAtPath:[IOSWineBottlePath(docs, @"arcade") stringByAppendingPathComponent:@"dosdevices/c:"] error:nil] isEqualToString:@"../drive_c"]);
    assert(!IOSWineRenameBottle(docs, @"arcade", @"Steam", &error));
    assert(IOSWineDuplicateBottle(docs, @"default", @"copy", &error) && !error);
    assert([fm fileExistsAtPath:[IOSWineBottlePath(docs, @"copy") stringByAppendingPathComponent:@"system.reg"]]);
    assert([[fm destinationOfSymbolicLinkAtPath:[IOSWineBottlePath(docs, @"copy") stringByAppendingPathComponent:@"dosdevices/c:"] error:nil] isEqualToString:@"../drive_c"]);
    assert([fm fileExistsAtPath:[docs stringByAppendingPathComponent:@"prefix/system.reg"]]);
    assert(!IOSWineDuplicateBottle(docs, @"arcade", @"copy", &error) && [error containsString:@"already"]);
    assert(!IOSWineDuplicateBottle(docs, @"missing", @"copy2", &error) && [error containsString:@"no bottle"]);
    assert(IOSWineDuplicateBottle(docs, @"Steam", @"steam-copy", &error));
    assert(([IOSWineBottleNames(docs) isEqual:@[ @"default", @"arcade", @"copy", @"Steam", @"steam-copy" ]]));
    assert([fm removeItemAtPath:base error:nil]);
    puts("BOTTLES PASS: names validated, template copy with drive links and stamp, listing, protected bottles, rename, duplicate");
  }
}

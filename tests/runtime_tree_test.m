#import "../src/ios/runtime_tree.h"
#include <assert.h>
#include <stdio.h>

static void put(NSString *root, NSString *name, NSString *text) {
  NSString *file = [root stringByAppendingPathComponent:name];
  assert([NSFileManager.defaultManager createDirectoryAtPath:file.stringByDeletingLastPathComponent
      withIntermediateDirectories:YES attributes:nil error:nil]);
  assert([text writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil]);
}

int main(void) {
  @autoreleasepool {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *testRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"kitsune-tree-test-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *current = [testRoot stringByAppendingPathComponent:@"wine"];
    NSString *candidate = [testRoot stringByAppendingPathComponent:@"candidate"];
    NSString *marker = @"lib/wine/aarch64-windows/ntdll.dll";
    put(current, @"TREE_VERSION", @"old");
    put(current, marker, @"old ntdll");
    put(testRoot, @"Apps/Doom/savegame", @"keep me");
    put(candidate, marker, @"new ntdll");

    NSError *error = nil;
    assert(!KitsuneInstallTree(candidate, current, @"new", &error));
    assert(error && KitsuneTreeMatches(current, @"old"));
    put(candidate, @"TREE_VERSION", @"wrong");
    assert(!KitsuneInstallTree(candidate, current, @"new", &error));
    assert(KitsuneTreeMatches(current, @"old"));
    put(candidate, @"TREE_VERSION", @"new\n");
    assert([fm removeItemAtPath:[candidate stringByAppendingPathComponent:marker] error:nil]);
    assert(!KitsuneInstallTree(candidate, current, @"new", &error));
    assert(KitsuneTreeMatches(current, @"old"));
    put(candidate, marker, @"new ntdll");
    assert(KitsuneInstallTree(candidate, current, @"new", &error));
    assert(KitsuneTreeMatches(current, @"new"));
    assert([fm fileExistsAtPath:[testRoot stringByAppendingPathComponent:@"Apps/Doom/savegame"]]);
    assert([fm contentsOfDirectoryAtPath:testRoot error:nil].count == 3);
    NSString *fresh = [testRoot stringByAppendingPathComponent:@"fresh/wine"];
    assert(KitsuneInstallTree(candidate, fresh, @"new", &error));
    assert(KitsuneTreeMatches(fresh, @"new"));
    assert([fm removeItemAtPath:testRoot error:nil]);
    puts("PASS: missing/wrong/incomplete trees preserve existing data; valid replacement and fresh install succeed");
  }
}

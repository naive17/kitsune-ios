/* Shared with the host regression test; no UIKit or device dependencies. */
#ifndef KITSUNE_RUNTIME_TREE_H
#define KITSUNE_RUNTIME_TREE_H
#import <Foundation/Foundation.h>

static inline NSString *KitsuneTreeVersion(NSString *root) {
  return [[NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"TREE_VERSION"]
                                   encoding:NSUTF8StringEncoding error:nil]
      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static inline BOOL KitsuneTreeMatches(NSString *root, NSString *version) {
  return version.length && [KitsuneTreeVersion(root) isEqualToString:version] &&
      [NSFileManager.defaultManager fileExistsAtPath:[root
          stringByAppendingPathComponent:@"lib/wine/aarch64-windows/ntdll.dll"]];
}

/* Never destroy a working tree to discover whether its replacement is valid.
 * Stage beside the destination so the final moves remain on one filesystem.
 * Keep the previous tree on a failed commit, including a failed rollback. */
static inline BOOL KitsuneInstallTree(NSString *source, NSString *destination,
                              NSString *version, NSError **error) {
  NSFileManager *fm = NSFileManager.defaultManager;
  if (!KitsuneTreeMatches(source, version)) {
    if (error) *error = [NSError errorWithDomain:@"kitsune.runtime" code:1 userInfo:@{
      NSLocalizedDescriptionKey: [NSString stringWithFormat:
          @"Tree version mismatch: got %@, need %@ (or ntdll.dll is missing). Existing tree preserved.",
          KitsuneTreeVersion(source) ?: @"(missing TREE_VERSION)", version]
    }];
    return NO;
  }
  NSString *parent = destination.stringByDeletingLastPathComponent;
  NSString *staging = [parent stringByAppendingPathComponent:
      [@".wine-install-" stringByAppendingString:NSUUID.UUID.UUIDString]];
  NSString *backup = [parent stringByAppendingPathComponent:
      [@".wine-previous-" stringByAppendingString:NSUUID.UUID.UUIDString]];
  if (![fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:error])
    return NO;
  if (![fm copyItemAtPath:source toPath:staging error:error]) {
    [fm removeItemAtPath:staging error:nil];
    return NO;
  }
  BOOL hadPrevious = [fm fileExistsAtPath:destination];
  if (hadPrevious && ![fm moveItemAtPath:destination toPath:backup error:error]) {
    [fm removeItemAtPath:staging error:nil];
    return NO;
  }
  if (![fm moveItemAtPath:staging toPath:destination error:error]) {
    if (hadPrevious) [fm moveItemAtPath:backup toPath:destination error:nil];
    [fm removeItemAtPath:staging error:nil];
    return NO;
  }
  if (hadPrevious) [fm removeItemAtPath:backup error:nil];
  return YES;
}
#endif

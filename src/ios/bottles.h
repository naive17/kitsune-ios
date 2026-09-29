/* Bottles: independent Wine prefixes under Documents/Bottles/<name>. */
#ifndef IOSWINE_BOTTLES_H
#define IOSWINE_BOTTLES_H

#import <Foundation/Foundation.h>
#include "launch_request.h"
#include "runtime_tree.h"

#define IOSWINE_DEFAULT_BOTTLE @"default"

/* Names of the bottles that have a registry, plus "default" for the app's
 * own prefix when it exists. Sorted, "default" first. */
static inline NSArray<NSString *> *IOSWineBottleNames(NSString *docs) {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSMutableArray *names = [NSMutableArray array];
  if ([fm fileExistsAtPath:[docs stringByAppendingPathComponent:@"prefix/system.reg"]])
    [names addObject:IOSWINE_DEFAULT_BOTTLE];
  NSMutableArray *others = [NSMutableArray array];
  NSString *root = [docs stringByAppendingPathComponent:@"Bottles"];
  for (NSString *n in [fm contentsOfDirectoryAtPath:root error:nil]) {
    if (!IOSWineBottleNameValid(n) || [n isEqualToString:IOSWINE_DEFAULT_BOTTLE]) continue;
    if ([fm fileExistsAtPath:[[root stringByAppendingPathComponent:n] stringByAppendingPathComponent:@"system.reg"]])
      [others addObject:n];
  }
  [others sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
  [names addObjectsFromArray:others];
  return names;
}

static inline NSString *IOSWineBottlePath(NSString *docs, NSString *name) {
  if (!name.length || [name isEqualToString:IOSWINE_DEFAULT_BOTTLE])
    return [docs stringByAppendingPathComponent:@"prefix"];
  return [[docs stringByAppendingPathComponent:@"Bottles"] stringByAppendingPathComponent:name];
}

/* Create a bottle from the tree's prefix template. */
static inline BOOL IOSWineCreateBottle(NSString *docs, NSString *treeRoot, NSString *name, NSString **error) {
  NSFileManager *fm = NSFileManager.defaultManager;
  if (!IOSWineBottleNameValid(name) || [name isEqualToString:IOSWINE_DEFAULT_BOTTLE]) {
    if (error) *error = NSLocalizedString(@"Use letters, digits, - or _ (at most 64), and not \"default\".", nil);
    return NO;
  }
  NSString *dest = IOSWineBottlePath(docs, name);
  if ([fm fileExistsAtPath:dest]) {
    if (error) *error = [NSString stringWithFormat:NSLocalizedString(@"A bottle named %@ already exists.", nil), name];
    return NO;
  }
  NSString *tmpl = [treeRoot stringByAppendingPathComponent:@"prefix-template"];
  if (![fm fileExistsAtPath:[tmpl stringByAppendingPathComponent:@"system.reg"]]) {
    if (error) *error = NSLocalizedString(@"The runtime tree has no prefix template.", nil);
    return NO;
  }
  NSError *err = nil;
  if (![fm createDirectoryAtPath:dest.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&err] ||
      ![fm copyItemAtPath:tmpl toPath:dest error:&err]) {
    [fm removeItemAtPath:dest error:nil];
    if (error) *error = err.localizedDescription ?: NSLocalizedString(@"copy failed", nil);
    return NO;
  }
  NSString *dd = [dest stringByAppendingPathComponent:@"dosdevices"];
  [fm createDirectoryAtPath:dd withIntermediateDirectories:YES attributes:nil error:nil];
  [fm removeItemAtPath:[dd stringByAppendingPathComponent:@"c:"] error:nil];
  [fm removeItemAtPath:[dd stringByAppendingPathComponent:@"z:"] error:nil];
  [fm createSymbolicLinkAtPath:[dd stringByAppendingPathComponent:@"c:"] withDestinationPath:@"../drive_c" error:nil];
  [fm createSymbolicLinkAtPath:[dd stringByAppendingPathComponent:@"z:"] withDestinationPath:@"/" error:nil];
  NSString *version = IOSWineTreeVersion(treeRoot) ?: @"";
  [version writeToFile:[dest stringByAppendingPathComponent:@".tree-stamp"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
  if (error) *error = nil;
  return YES;
}

/* Recreate the default prefix from the tree's template. Used after a reset
 * so programs assigned to the default bottle keep a place to run. */
static inline BOOL IOSWineCreateDefaultPrefix(NSString *docs, NSString *treeRoot, NSString **error) {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSString *dest = IOSWineBottlePath(docs, nil);
  NSString *tmpl = [treeRoot stringByAppendingPathComponent:@"prefix-template"];
  if ([fm fileExistsAtPath:[dest stringByAppendingPathComponent:@"system.reg"]]) return YES;
  if (![fm fileExistsAtPath:[tmpl stringByAppendingPathComponent:@"system.reg"]]) {
    if (error) *error = NSLocalizedString(@"The runtime tree has no prefix template.", nil);
    return NO;
  }
  NSError *err = nil;
  [fm removeItemAtPath:dest error:nil];
  if (![fm copyItemAtPath:tmpl toPath:dest error:&err]) {
    if (error) *error = err.localizedDescription ?: NSLocalizedString(@"copy failed", nil);
    return NO;
  }
  NSString *dd = [dest stringByAppendingPathComponent:@"dosdevices"];
  [fm createDirectoryAtPath:dd withIntermediateDirectories:YES attributes:nil error:nil];
  [fm removeItemAtPath:[dd stringByAppendingPathComponent:@"c:"] error:nil];
  [fm removeItemAtPath:[dd stringByAppendingPathComponent:@"z:"] error:nil];
  [fm createSymbolicLinkAtPath:[dd stringByAppendingPathComponent:@"c:"] withDestinationPath:@"../drive_c" error:nil];
  [fm createSymbolicLinkAtPath:[dd stringByAppendingPathComponent:@"z:"] withDestinationPath:@"/" error:nil];
  [(IOSWineTreeVersion(treeRoot) ?: @"") writeToFile:[dest stringByAppendingPathComponent:@".tree-stamp"]
                                        atomically:YES encoding:NSUTF8StringEncoding error:nil];
  if (error) *error = nil;
  return YES;
}

/* Delete a user bottle and everything installed in it. The default prefix
 * and the Steam bottle have their own paths in the launcher. */
static inline BOOL IOSWineDeleteBottle(NSString *docs, NSString *name, NSString **error) {
  if (!IOSWineBottleNameValid(name) || [name isEqualToString:IOSWINE_DEFAULT_BOTTLE] || [name isEqualToString:@"Steam"]) {
    if (error) *error = NSLocalizedString(@"This bottle cannot be deleted.", nil);
    return NO;
  }
  NSError *err = nil;
  if (![NSFileManager.defaultManager removeItemAtPath:IOSWineBottlePath(docs, name) error:&err]) {
    if (error) *error = err.localizedDescription;
    return NO;
  }
  if (error) *error = nil;
  return YES;
}

/* Names the user can give a bottle: valid, and not the two the app finds by
 * name. */
static inline BOOL IOSWineBottleNameFree(NSString *docs, NSString *name, NSString **error) {
  if (!IOSWineBottleNameValid(name) || [name isEqualToString:IOSWINE_DEFAULT_BOTTLE] || [name isEqualToString:@"Steam"]) {
    if (error) *error = NSLocalizedString(@"Use letters, digits, - or _ (at most 64), and not \"default\" or \"Steam\".", nil);
    return NO;
  }
  if ([NSFileManager.defaultManager fileExistsAtPath:IOSWineBottlePath(docs, name)]) {
    if (error) *error = [NSString stringWithFormat:NSLocalizedString(@"A bottle named %@ already exists.", nil), name];
    return NO;
  }
  return YES;
}

/* Rename a user bottle; the default bottle and Steam keep their names. */
static inline BOOL IOSWineRenameBottle(NSString *docs, NSString *from, NSString *to, NSString **error) {
  if (!IOSWineBottleNameValid(from) || [from isEqualToString:IOSWINE_DEFAULT_BOTTLE] || [from isEqualToString:@"Steam"]) {
    if (error) *error = NSLocalizedString(@"This bottle cannot be renamed.", nil);
    return NO;
  }
  if (!IOSWineBottleNameFree(docs, to, error)) return NO;
  NSError *err = nil;
  if (![NSFileManager.defaultManager moveItemAtPath:IOSWineBottlePath(docs, from) toPath:IOSWineBottlePath(docs, to) error:&err]) {
    if (error) *error = err.localizedDescription ?: NSLocalizedString(@"rename failed", nil);
    return NO;
  }
  if (error) *error = nil;
  return YES;
}

/* Copy any bottle, including the default one and Steam's, under a new name. */
static inline BOOL IOSWineDuplicateBottle(NSString *docs, NSString *from, NSString *to, NSString **error) {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSString *source = IOSWineBottlePath(docs, from);
  if (![fm fileExistsAtPath:[source stringByAppendingPathComponent:@"system.reg"]]) {
    if (error) *error = [NSString stringWithFormat:NSLocalizedString(@"There is no bottle named %@.", nil), from];
    return NO;
  }
  if (!IOSWineBottleNameFree(docs, to, error)) return NO;
  NSString *dest = IOSWineBottlePath(docs, to);
  NSError *err = nil;
  if (![fm createDirectoryAtPath:dest.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&err] ||
      ![fm copyItemAtPath:source toPath:dest error:&err]) {
    [fm removeItemAtPath:dest error:nil];
    if (error) *error = err.localizedDescription ?: NSLocalizedString(@"copy failed", nil);
    return NO;
  }
  if (error) *error = nil;
  return YES;
}

#endif

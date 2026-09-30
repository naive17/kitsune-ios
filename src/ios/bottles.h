/* Bottles: independent Wine prefixes under Documents/Bottles/<name>. */
#ifndef KITSUNE_BOTTLES_H
#define KITSUNE_BOTTLES_H

#import <Foundation/Foundation.h>
#include "launch_request.h"
#include "runtime_tree.h"

#define KITSUNE_DEFAULT_BOTTLE @"default"

/* Names of the bottles that have a registry, plus "default" for the app's
 * own prefix when it exists. Sorted, "default" first. */
static inline NSArray<NSString *> *KitsuneBottleNames(NSString *docs) {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSMutableArray *names = [NSMutableArray array];
  if ([fm fileExistsAtPath:[docs stringByAppendingPathComponent:@"prefix/system.reg"]])
    [names addObject:KITSUNE_DEFAULT_BOTTLE];
  NSMutableArray *others = [NSMutableArray array];
  NSString *root = [docs stringByAppendingPathComponent:@"Bottles"];
  for (NSString *n in [fm contentsOfDirectoryAtPath:root error:nil]) {
    if (!KitsuneBottleNameValid(n) || [n isEqualToString:KITSUNE_DEFAULT_BOTTLE]) continue;
    if ([fm fileExistsAtPath:[[root stringByAppendingPathComponent:n] stringByAppendingPathComponent:@"system.reg"]])
      [others addObject:n];
  }
  [others sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
  [names addObjectsFromArray:others];
  return names;
}

static inline NSString *KitsuneBottlePath(NSString *docs, NSString *name) {
  if (!name.length || [name isEqualToString:KITSUNE_DEFAULT_BOTTLE])
    return [docs stringByAppendingPathComponent:@"prefix"];
  return [[docs stringByAppendingPathComponent:@"Bottles"] stringByAppendingPathComponent:name];
}

/* Create a bottle from the tree's prefix template. */
static inline BOOL KitsuneCreateBottle(NSString *docs, NSString *treeRoot, NSString *name, NSString **error) {
  NSFileManager *fm = NSFileManager.defaultManager;
  if (!KitsuneBottleNameValid(name) || [name isEqualToString:KITSUNE_DEFAULT_BOTTLE]) {
    if (error) *error = NSLocalizedString(@"Use letters, digits, - or _ (at most 64), and not \"default\".", nil);
    return NO;
  }
  NSString *dest = KitsuneBottlePath(docs, name);
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
  NSString *version = KitsuneTreeVersion(treeRoot) ?: @"";
  [version writeToFile:[dest stringByAppendingPathComponent:@".tree-stamp"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
  if (error) *error = nil;
  return YES;
}

/* Recreate the default prefix from the tree's template. Used after a reset
 * so programs assigned to the default bottle keep a place to run. */
static inline BOOL KitsuneCreateDefaultPrefix(NSString *docs, NSString *treeRoot, NSString **error) {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSString *dest = KitsuneBottlePath(docs, nil);
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
  [(KitsuneTreeVersion(treeRoot) ?: @"") writeToFile:[dest stringByAppendingPathComponent:@".tree-stamp"]
                                        atomically:YES encoding:NSUTF8StringEncoding error:nil];
  if (error) *error = nil;
  return YES;
}

/* Delete a user bottle and everything installed in it. The default prefix
 * and the Steam bottle have their own paths in the launcher. */
static inline BOOL KitsuneDeleteBottle(NSString *docs, NSString *name, NSString **error) {
  if (!KitsuneBottleNameValid(name) || [name isEqualToString:KITSUNE_DEFAULT_BOTTLE] || [name isEqualToString:@"Steam"]) {
    if (error) *error = NSLocalizedString(@"This bottle cannot be deleted.", nil);
    return NO;
  }
  NSError *err = nil;
  if (![NSFileManager.defaultManager removeItemAtPath:KitsuneBottlePath(docs, name) error:&err]) {
    if (error) *error = err.localizedDescription;
    return NO;
  }
  if (error) *error = nil;
  return YES;
}

/* Names the user can give a bottle: valid, and not the two the app finds by
 * name. */
static inline BOOL KitsuneBottleNameFree(NSString *docs, NSString *name, NSString **error) {
  if (!KitsuneBottleNameValid(name) || [name isEqualToString:KITSUNE_DEFAULT_BOTTLE] || [name isEqualToString:@"Steam"]) {
    if (error) *error = NSLocalizedString(@"Use letters, digits, - or _ (at most 64), and not \"default\" or \"Steam\".", nil);
    return NO;
  }
  if ([NSFileManager.defaultManager fileExistsAtPath:KitsuneBottlePath(docs, name)]) {
    if (error) *error = [NSString stringWithFormat:NSLocalizedString(@"A bottle named %@ already exists.", nil), name];
    return NO;
  }
  return YES;
}

/* Rename a user bottle; the default bottle and Steam keep their names. */
static inline BOOL KitsuneRenameBottle(NSString *docs, NSString *from, NSString *to, NSString **error) {
  if (!KitsuneBottleNameValid(from) || [from isEqualToString:KITSUNE_DEFAULT_BOTTLE] || [from isEqualToString:@"Steam"]) {
    if (error) *error = NSLocalizedString(@"This bottle cannot be renamed.", nil);
    return NO;
  }
  if (!KitsuneBottleNameFree(docs, to, error)) return NO;
  NSError *err = nil;
  if (![NSFileManager.defaultManager moveItemAtPath:KitsuneBottlePath(docs, from) toPath:KitsuneBottlePath(docs, to) error:&err]) {
    if (error) *error = err.localizedDescription ?: NSLocalizedString(@"rename failed", nil);
    return NO;
  }
  if (error) *error = nil;
  return YES;
}

/* Copy any bottle, including the default one and Steam's, under a new name. */
static inline BOOL KitsuneDuplicateBottle(NSString *docs, NSString *from, NSString *to, NSString **error) {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSString *source = KitsuneBottlePath(docs, from);
  if (![fm fileExistsAtPath:[source stringByAppendingPathComponent:@"system.reg"]]) {
    if (error) *error = [NSString stringWithFormat:NSLocalizedString(@"There is no bottle named %@.", nil), from];
    return NO;
  }
  if (!KitsuneBottleNameFree(docs, to, error)) return NO;
  NSString *dest = KitsuneBottlePath(docs, to);
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

/* Bring a bottle made from an older template up to the current one, before
 * Wine runs. Without AppData\LocalLow a Unity game recurses on a relative save
 * path until its stack overflows; without the Time Zones table and tzres.dll
 * (the file the zone names are loaded from) GetTimeZoneInformation returns no
 * name and Mono throws. The template's zone sections are appended to
 * system.reg, and Wine merges them into the empty key it already has. */
static inline void KitsuneRepairBottle(NSString *prefix, NSString *treeRoot) {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSString *tmpl = [treeRoot stringByAppendingPathComponent:@"prefix-template"];

  NSString *users = [prefix stringByAppendingPathComponent:@"drive_c/users"];
  for (NSString *user in [fm contentsOfDirectoryAtPath:users error:nil]) {
    NSString *appData = [[users stringByAppendingPathComponent:user] stringByAppendingPathComponent:@"AppData"];
    BOOL dir = NO;
    if (![user isEqualToString:@"Public"] && [fm fileExistsAtPath:appData isDirectory:&dir] && dir)
      [fm createDirectoryAtPath:[appData stringByAppendingPathComponent:@"LocalLow"]
    withIntermediateDirectories:YES attributes:nil error:nil];
  }

  NSString *tzres = @"drive_c/windows/system32/tzres.dll";
  NSString *have = [prefix stringByAppendingPathComponent:tzres];
  NSString *want = [tmpl stringByAppendingPathComponent:tzres];
  if (![fm fileExistsAtPath:have] && [fm fileExistsAtPath:want]) {
    [fm createDirectoryAtPath:have.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [fm copyItemAtPath:want toPath:have error:nil];
  }

  NSString *zones = @"[Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\Time Zones\\\\";
  NSString *regPath = [prefix stringByAppendingPathComponent:@"system.reg"];
  NSString *reg = [NSString stringWithContentsOfFile:regPath encoding:NSUTF8StringEncoding error:nil];
  NSString *source = [NSString stringWithContentsOfFile:[tmpl stringByAppendingPathComponent:@"system.reg"]
                                              encoding:NSUTF8StringEncoding error:nil];
  if (!reg || [reg containsString:zones] || ![source containsString:zones]) return;
  NSMutableString *add = [NSMutableString stringWithString:@"\n"];
  BOOL copying = NO;
  for (NSString *line in [source componentsSeparatedByString:@"\n"]) {
    if ([line hasPrefix:@"["]) copying = [line hasPrefix:zones];
    if (copying) [add appendFormat:@"%@\n", line];
  }
  NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:regPath];
  [h seekToEndOfFile];
  [h writeData:[add dataUsingEncoding:NSUTF8StringEncoding]];
  [h closeFile];
}

#endif

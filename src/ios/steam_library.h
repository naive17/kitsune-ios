/*
 * The Steam library, read from Steam's own manifests.
 *
 * Steam writes one appmanifest_<appid>.acf per installed title under
 * steamapps/, in Valve's KeyValues text format. That file is the truth about
 * what is installed: name, install directory and a StateFlags word whose bit
 * 2 (4) means "fully installed". Reading it is how the launcher lists games
 * without hardcoding one, and how it refuses to launch a half-downloaded one.
 *
 * Only the subset of KeyValues that appmanifests use is parsed: quoted keys,
 * quoted values, nested braces, // comments and the four backslash escapes.
 * Anything else is an error for that file, not a crash, and the file is
 * skipped.
 */
#ifndef KITSUNE_STEAM_LIBRARY_H
#define KITSUNE_STEAM_LIBRARY_H

#import <Foundation/Foundation.h>

/* Returns the top-level object (the value under the file's single root key,
 * e.g. "AppState"), or nil when the text is not well-formed KeyValues. */
static inline NSDictionary *KitsuneParseKeyValues(NSString *text) {
  if (![text isKindOfClass:NSString.class] || !text.length || text.length > 4 * 1024 * 1024) return nil;
  __block NSUInteger i = 0;
  NSUInteger n = text.length;
  NSMutableArray<NSMutableDictionary *> *stack = [NSMutableArray array];
  NSMutableDictionary *root = [NSMutableDictionary dictionary];
  [stack addObject:root];
  NSString *pendingKey = nil;

  NSString *(^readToken)(void) = ^NSString *{
    /* Caller has positioned i at a non-space; returns nil at a brace or on
     * an unterminated string. Unquoted tokens are allowed (Steam writes
     * numbers quoted, but be lenient). */
    if (i >= n) return nil;
    unichar c = [text characterAtIndex:i];
    NSMutableString *out = [NSMutableString string];
    if (c == '"') {
      i++;
      while (i < n) {
        unichar d = [text characterAtIndex:i++];
        if (d == '"') return out;
        if (d == '\\' && i < n) {
          unichar e = [text characterAtIndex:i++];
          switch (e) {
          case 'n': [out appendString:@"\n"]; break;
          case 't': [out appendString:@"\t"]; break;
          case '\\': [out appendString:@"\\"]; break;
          case '"': [out appendString:@"\""]; break;
          default: [out appendFormat:@"\\%C", e]; break;
          }
          continue;
        }
        [out appendFormat:@"%C", d];
      }
      return nil; /* unterminated */
    }
    while (i < n) {
      unichar d = [text characterAtIndex:i];
      if (d == '"' || d == '{' || d == '}' || d == ' ' || d == '\t' || d == '\r' || d == '\n') break;
      [out appendFormat:@"%C", d];
      i++;
    }
    return out.length ? out : nil;
  };

  while (i < n) {
    unichar c = [text characterAtIndex:i];
    if (c == ' ' || c == '\t' || c == '\r' || c == '\n') { i++; continue; }
    if (c == '/' && i + 1 < n && [text characterAtIndex:i + 1] == '/') {
      while (i < n && [text characterAtIndex:i] != '\n') i++;
      continue;
    }
    if (c == '{') {
      if (!pendingKey) return nil;
      NSMutableDictionary *child = [NSMutableDictionary dictionary];
      stack.lastObject[pendingKey] = child;
      [stack addObject:child];
      pendingKey = nil;
      i++;
      continue;
    }
    if (c == '}') {
      if (pendingKey || stack.count < 2) return nil;
      [stack removeLastObject];
      i++;
      continue;
    }
    NSString *tok = readToken();
    if (!tok) return nil;
    if (!pendingKey) { pendingKey = tok; continue; }
    stack.lastObject[pendingKey] = tok;
    pendingKey = nil;
  }
  if (pendingKey || stack.count != 1) return nil;
  /* The file is "AppState" { ... }: unwrap the single root object. */
  if (root.count == 1 && [root.allValues.firstObject isKindOfClass:NSDictionary.class])
    return root.allValues.firstObject;
  return root;
}

/* Whether a game directory holds a Unity player: UnityPlayer.dll (Unity 2017.2
 * and later) or the Mono runtime Unity ships beside it. */
static inline BOOL KitsuneGameDirIsUnity(NSString *path) {
  NSFileManager *fm = NSFileManager.defaultManager;
  return [fm fileExistsAtPath:[path stringByAppendingPathComponent:@"UnityPlayer.dll"]] ||
         [fm fileExistsAtPath:[path stringByAppendingPathComponent:@"MonoBleedingEdge"]];
}

/* One installed title. Keys: appid, name, installdir, path (unix path of the
 * game directory), manifest (unix path), installed (NSNumber BOOL), size
 * (NSNumber bytes), unity (NSNumber BOOL). Sorted by name. Titles whose
 * directory is missing are left out: a manifest without files cannot be launched. */
static inline NSArray<NSDictionary *> *KitsuneSteamGames(NSString *steamRoot) {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSString *apps = [steamRoot stringByAppendingPathComponent:@"steamapps"];
  NSMutableArray<NSDictionary *> *games = [NSMutableArray array];
  for (NSString *name in [fm contentsOfDirectoryAtPath:apps error:nil]) {
    if (![name hasPrefix:@"appmanifest_"] || ![name.pathExtension isEqualToString:@"acf"]) continue;
    NSString *manifest = [apps stringByAppendingPathComponent:name];
    NSString *text = [NSString stringWithContentsOfFile:manifest encoding:NSUTF8StringEncoding error:nil];
    NSDictionary *state = KitsuneParseKeyValues(text);
    NSString *appid = state[@"appid"], *title = state[@"name"], *dir = state[@"installdir"];
    if (![appid isKindOfClass:NSString.class] || ![title isKindOfClass:NSString.class] ||
        ![dir isKindOfClass:NSString.class] || !appid.length || !dir.length)
      continue;
    if ([appid rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound)
      continue;
    if ([dir containsString:@"/"] || [dir containsString:@"\\"] || [dir isEqualToString:@".."]) continue;
    NSString *path = [[apps stringByAppendingPathComponent:@"common"] stringByAppendingPathComponent:dir];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir] || !isDir) continue;
    unsigned long long flags = [state[@"StateFlags"] isKindOfClass:NSString.class]
        ? strtoull([state[@"StateFlags"] UTF8String], NULL, 10) : 0;
    unsigned long long size = [state[@"SizeOnDisk"] isKindOfClass:NSString.class]
        ? strtoull([state[@"SizeOnDisk"] UTF8String], NULL, 10) : 0;
    [games addObject:@{
      @"appid": appid,
      @"name": title.length ? title : dir,
      @"installdir": dir,
      @"path": path,
      @"manifest": manifest,
      @"installed": @((flags & 4) != 0),
      @"size": @(size),
      @"unity": @(KitsuneGameDirIsUnity(path)),
    }];
  }
  [games sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
    return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
  }];
  return games;
}

/* Where the launcher expects Steam: Documents/Apps/Steam/steam.exe, where the
 * Steam install puts it. nil when it is not there. */
static inline NSString *KitsuneSteamRoot(NSString *docs) {
  NSString *root = [docs stringByAppendingPathComponent:@"Apps/Steam"];
  BOOL isDir = NO;
  if (![NSFileManager.defaultManager fileExistsAtPath:[root stringByAppendingPathComponent:@"steam.exe"]
                                          isDirectory:&isDir] || isDir)
    return nil;
  return root;
}

#endif

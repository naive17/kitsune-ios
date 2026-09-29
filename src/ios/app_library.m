/* The imported/installed program catalogue. See app_library.h. */
#import "app_library.h"
#include "wine_boot.h"   /* IOSWinePersistentDocuments() */

#include "zip.h"

#include <sys/stat.h>

/* Registering every .exe in a large game directory would bury the one the user
 * wants under its redistributables and crash handlers. */
#define MAX_EXES_PER_IMPORT 12
/* A prefix scan walks installer output, which nests deeply and pointlessly. */
#define MAX_SCAN_DEPTH 6

@implementation WineApp

- (NSString *)archLabel {
  switch (self.arch) {
  case PE_ARCH_ARM64:
  case PE_ARCH_ARM64EC:
  case PE_ARCH_ARM64X:
    return NSLocalizedString(@"ARM64", nil);
  case PE_ARCH_AMD64:
    return NSLocalizedString(@"x86-64", nil);
  case PE_ARCH_I386:
    return NSLocalizedString(@"32-bit x86", nil);
  case PE_ARCH_ARMNT:
    return NSLocalizedString(@"32-bit ARM", nil);
  default:
    return NSLocalizedString(@"Unknown", nil);
  }
}

- (BOOL)runnableWithWow64:(BOOL)haveWow64 {
  return pe_arch_runnable(self.arch, haveWow64 ? 1 : 0) != 0;
}

- (NSDictionary *)toDictionary {
  return @{
    @"uid"        : self.uid ?: @"",
    @"name"       : self.name ?: @"",
    @"exePath"    : self.exePath ?: @"",
    @"workingDir" : self.workingDir ?: @"",
    @"machine"    : @(self.arch),
    @"subsystem"  : @(self.subsystem),
    @"origin"     : @(self.origin),
    @"addedAt"    : @(self.addedAt.timeIntervalSince1970),
    @"arguments"  : self.arguments ?: @"",
    @"bottle"     : self.bottle ?: @"",
  };
}

+ (WineApp *)fromDictionary:(NSDictionary *)d {
  WineApp *a = [WineApp new];

  a.uid        = d[@"uid"];
  a.name       = d[@"name"];
  a.exePath    = d[@"exePath"];
  a.workingDir = d[@"workingDir"];
  a.arch       = (pe_arch)[d[@"machine"] integerValue];
  a.subsystem  = (pe_subsystem)[d[@"subsystem"] integerValue];
  a.origin     = (WineAppOrigin)[d[@"origin"] integerValue];
  a.addedAt    = [NSDate dateWithTimeIntervalSince1970:[d[@"addedAt"] doubleValue]];
  a.arguments  = d[@"arguments"];
  a.bottle     = [d[@"bottle"] length] ? d[@"bottle"] : nil;
  return a;
}

@end

@implementation WineAppLibrary {
  NSMutableArray<WineApp *> *_apps;
}

+ (instancetype)shared {
  static WineAppLibrary *s;
  static dispatch_once_t once;

  dispatch_once(&once, ^{ s = [WineAppLibrary new]; [s load]; });
  return s;
}

- (instancetype)init {
  if ((self = [super init])) _apps = [NSMutableArray array];
  return self;
}

- (NSArray<WineApp *> *)apps { return _apps; }

+ (NSString *)appsRoot {
  /* The imported programs live here, in Documents. */
  NSString *root = [IOSWinePersistentDocuments() stringByAppendingPathComponent:@"Apps"];

  [NSFileManager.defaultManager createDirectoryAtPath:root
                          withIntermediateDirectories:YES
                                           attributes:nil error:nil];
  return root;
}

+ (NSString *)catalogPath {
  return [[self appsRoot] stringByAppendingPathComponent:@"library.json"];
}

- (void)load {
  NSData *data = [NSData dataWithContentsOfFile:[WineAppLibrary catalogPath]];
  NSArray *raw = nil;

  [_apps removeAllObjects];
  if (data.length) {
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([parsed isKindOfClass:NSArray.class]) raw = parsed;
  }

  for (NSDictionary *d in raw) {
    WineApp *a;

    if (![d isKindOfClass:NSDictionary.class]) continue;
    a = [WineApp fromDictionary:d];
    if (a.exePath.length &&
        [NSFileManager.defaultManager fileExistsAtPath:a.exePath])
      [_apps addObject:a];
  }
}

- (void)save {
  NSMutableArray *raw = [NSMutableArray array];
  NSData *data;

  for (WineApp *a in _apps) [raw addObject:[a toDictionary]];
  data = [NSJSONSerialization dataWithJSONObject:raw
                                         options:NSJSONWritingPrettyPrinted
                                           error:nil];
  [data writeToFile:[WineAppLibrary catalogPath] atomically:YES];
}

- (void)remove:(WineApp *)app {
  /* Only imported trees are ours to delete. An installed program lives in the
   * prefix and removing its files would leave the registry describing it. */
  if (app.origin == WineAppOriginImported) {
    NSString *dir = [[WineAppLibrary appsRoot] stringByAppendingPathComponent:app.uid];

    if ([dir hasPrefix:[WineAppLibrary appsRoot]] && app.uid.length)
      [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
  }
  [_apps removeObject:app];
  [self save];
}

/* ------------------------------------------------------------------ helpers */

static NSString *SlugFor(NSString *name) {
  NSMutableString *s = [NSMutableString string];
  NSCharacterSet *ok = [NSCharacterSet
      characterSetWithCharactersInString:
          @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"];

  for (NSUInteger i = 0; i < name.length && s.length < 40; i++) {
    unichar c = [name characterAtIndex:i];

    [s appendString:[ok characterIsMember:c] ? [NSString stringWithCharacters:&c length:1]
                                             : @"-"];
  }
  if (!s.length) [s setString:@"app"];
  /* Time-suffixed rather than checked-for-collision: two imports of the same
   * archive are two separate installs and must not share a directory. */
  return [NSString stringWithFormat:@"%@-%08x", s,
                   (unsigned)(NSUInteger)(NSDate.date.timeIntervalSince1970)];
}

static BOOL ReadPE(NSString *path, pe_info *info) {
  return pe_info_read(path.fileSystemRepresentation, info, NULL, 0) == 0;
}

static BOOL IsNoise(NSString *base) {
  static NSArray *noise;
  static dispatch_once_t once;

  dispatch_once(&once, ^{
    noise = @[ @"unins", @"uninstall", @"vcredist", @"dxsetup", @"dotnetfx",
               @"crashreport", @"crashhandler", @"werfault", @"setup_dx" ];
  });
  NSString *low = base.lowercaseString;

  for (NSString *n in noise)
    if ([low containsString:n]) return YES;
  return NO;
}

static NSInteger ScoreExe(NSString *path, NSString *root, pe_info info) {
  NSString *base = path.lastPathComponent.stringByDeletingPathExtension;
  NSString *rel = [path hasPrefix:root] ? [path substringFromIndex:root.length] : path;
  NSInteger depth = rel.pathComponents.count;
  NSInteger score = 100 - depth * 10;

  if ([base.lowercaseString isEqualToString:root.lastPathComponent.lowercaseString])
    score += 60;
  if (info.subsystem == PE_SUBSYSTEM_GUI) score += 25;
  if (IsNoise(base)) score -= 200;
  return score;
}

/* Every .exe under `root`, bounded in depth so a pathological tree cannot
 * make the import appear to hang. */
static NSArray<NSString *> *FindExes(NSString *root, NSInteger maxDepth) {
  NSMutableArray *found = [NSMutableArray array];
  NSDirectoryEnumerator *e =
      [NSFileManager.defaultManager enumeratorAtPath:root];

  for (NSString *rel in e) {
    if ((NSInteger)e.level > maxDepth) { [e skipDescendants]; continue; }
    if (![rel.pathExtension.lowercaseString isEqualToString:@"exe"]) continue;
    [found addObject:[root stringByAppendingPathComponent:rel]];
  }
  return found;
}

- (NSArray<WineApp *> *)catalogExes:(NSArray<NSString *> *)paths
                             inRoot:(NSString *)root
                                uid:(NSString *)uid
                             origin:(WineAppOrigin)origin {
  NSMutableArray<WineApp *> *added = [NSMutableArray array];
  NSMutableArray *scored = [NSMutableArray array];

  for (NSString *p in paths) {
    pe_info info;

    if (!ReadPE(p, &info)) continue;   /* a .exe that is not a PE at all */
    [scored addObject:@{ @"path"  : p,
                         @"score" : @(ScoreExe(p, root, info)),
                         @"arch"  : @(info.arch),
                         @"sub"   : @(info.subsystem) }];
  }
  [scored sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
    return [b[@"score"] compare:a[@"score"]];
  }];

  for (NSDictionary *d in scored) {
    WineApp *app;

    if (added.count >= MAX_EXES_PER_IMPORT) break;
    app = [WineApp new];
    app.uid        = uid;
    app.name       = [d[@"path"] lastPathComponent].stringByDeletingPathExtension;
    app.exePath    = d[@"path"];
    app.workingDir = [d[@"path"] stringByDeletingLastPathComponent];
    app.arch       = (pe_arch)[d[@"arch"] integerValue];
    app.subsystem  = (pe_subsystem)[d[@"sub"] integerValue];
    app.origin     = origin;
    app.addedAt    = NSDate.date;
    [added addObject:app];
  }
  return added;
}

/* ------------------------------------------------------------------- import */

- (NSArray<WineApp *> *)importFileAtURL:(NSURL *)url
                               progress:(void (^)(NSString *))progress
                                  error:(NSString **)err {
  NSString *ext = url.pathExtension.lowercaseString;
  NSString *display = url.lastPathComponent.stringByDeletingPathExtension;
  NSString *uid = SlugFor(display);
  NSString *dest = [[WineAppLibrary appsRoot] stringByAppendingPathComponent:uid];
  NSArray<WineApp *> *added = nil;
  void (^say)(NSString *) = progress ?: ^(NSString *l __unused){};

  BOOL scoped = [url startAccessingSecurityScopedResource];

  @try {
    if ([ext isEqualToString:@"zip"]) {
      zip_reader *z = NULL;
      char zerr[256] = "";
      size_t skipped = 0;

      say([NSString stringWithFormat:NSLocalizedString(@"opening %@", nil), url.lastPathComponent]);
      if (zip_open(url.path.fileSystemRepresentation, &z, zerr, sizeof(zerr)) != 0) {
        if (err) *err = [NSString stringWithFormat:@"%s", zerr];
        return nil;
      }
      say([NSString stringWithFormat:NSLocalizedString(@"extracting %zu entries", nil), zip_count(z)]);
      if (zip_extract_all(z, dest.fileSystemRepresentation, NULL, NULL,
                          &skipped, zerr, sizeof(zerr)) != 0) {
        zip_close(z);
        if (err) *err = [NSString stringWithFormat:@"%s", zerr];
        return nil;
      }
      zip_close(z);
      if (skipped)
        say([NSString stringWithFormat:
                NSLocalizedString(@"%zu entries were skipped as unsafe or unreadable", nil), skipped]);

      added = [self catalogExes:FindExes(dest, MAX_SCAN_DEPTH)
                         inRoot:dest uid:uid origin:WineAppOriginImported];
      if (!added.count) {
        if (err) *err = NSLocalizedString(@"the archive contains no runnable .exe", nil);
        [NSFileManager.defaultManager removeItemAtPath:dest error:nil];
        return nil;
      }
    } else if ([ext isEqualToString:@"exe"] || [ext isEqualToString:@"msi"]) {
      NSString *file = [dest stringByAppendingPathComponent:url.lastPathComponent];

      [NSFileManager.defaultManager createDirectoryAtPath:dest
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];
      [NSFileManager.defaultManager removeItemAtPath:file error:nil];
      if (![NSFileManager.defaultManager copyItemAtPath:url.path toPath:file error:nil]) {
        if (err) *err = NSLocalizedString(@"could not copy the file in", nil);
        return nil;
      }
      if ([ext isEqualToString:@"msi"]) {
        WineApp *app = [WineApp new];

        app.uid = uid;
        app.name = display;
        app.exePath = file;
        app.workingDir = dest;
        app.arch = PE_ARCH_ARM64;   /* msiexec is what actually runs */
        app.subsystem = PE_SUBSYSTEM_GUI;
        app.origin = WineAppOriginImported;
        app.addedAt = NSDate.date;
        added = @[ app ];
      } else {
        added = [self catalogExes:@[ file ] inRoot:dest uid:uid
                           origin:WineAppOriginImported];
        if (!added.count) {
          if (err) *err = NSLocalizedString(@"that .exe is not a PE image this build can read", nil);
          [NSFileManager.defaultManager removeItemAtPath:dest error:nil];
          return nil;
        }
      }
    } else {
      if (err) *err = [NSString stringWithFormat:NSLocalizedString(@"unsupported file type .%@", nil), ext];
      return nil;
    }
  } @finally {
    if (scoped) [url stopAccessingSecurityScopedResource];
  }

  [_apps addObjectsFromArray:added];
  [self save];
  return added;
}

/* ------------------------------------------------------------------- rescan */

- (BOOL)hasExeAtPath:(NSString *)path {
  for (WineApp *a in _apps)
    if ([a.exePath isEqualToString:path]) return YES;
  return NO;
}

- (NSUInteger)rescanInstalledInPrefix:(NSString *)prefix {
  NSString *cdrive = [prefix stringByAppendingPathComponent:@"drive_c"];
  NSUInteger added = 0;

  for (NSString *sub in @[ @"Program Files", @"Program Files (x86)" ]) {
    NSString *root = [cdrive stringByAppendingPathComponent:sub];
    NSArray *exes;

    if (![NSFileManager.defaultManager fileExistsAtPath:root]) continue;
    exes = FindExes(root, MAX_SCAN_DEPTH);
    for (WineApp *a in [self catalogExes:exes inRoot:root uid:@""
                                  origin:WineAppOriginInstalled]) {
      if ([self hasExeAtPath:a.exePath]) continue;
      /* Installed programs keep their own uid so removing one never deletes a
       * directory shared with an import. */
      a.uid = SlugFor(a.name);
      [_apps addObject:a];
      added++;
    }
  }
  if (added) [self save];
  return added;
}

- (NSUInteger)rescanBuiltinsInTree:(NSString *)treeRoot {
  NSString *pe = [treeRoot stringByAppendingPathComponent:@"lib/wine/aarch64-windows"];
  NSUInteger added = 0;

  for (NSString *name in @[ @"notepad.exe", @"cmd.exe", @"winemine.exe",
                            @"regedit.exe", @"winecfg.exe" ]) {
    NSString *full = [pe stringByAppendingPathComponent:name];
    pe_info info;

    if (![NSFileManager.defaultManager fileExistsAtPath:full]) continue;
    if ([self hasExeAtPath:full]) continue;
    if (!ReadPE(full, &info)) continue;

    WineApp *a = [WineApp new];

    a.uid        = [@"builtin-" stringByAppendingString:name];
    a.name       = name.stringByDeletingPathExtension;
    a.exePath    = full;
    a.workingDir = pe;
    a.arch       = info.arch;
    a.subsystem  = info.subsystem;
    a.origin     = WineAppOriginBuiltin;
    a.addedAt    = NSDate.date;
    [_apps addObject:a];
    added++;
  }
  if (added) [self save];
  return added;
}

@end

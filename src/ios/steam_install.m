#import "steam_install.h"

#import <CommonCrypto/CommonDigest.h>
#include <sys/time.h>
#include "vz.h"
#include "zip.h"

static BOOL g_running;
static volatile int g_cancel;
static NSURLSessionTask *g_task;

static NSString *SHA256Hex(NSString *path) {
  NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
  if (!fh) return nil;
  CC_SHA256_CTX ctx;
  CC_SHA256_Init(&ctx);
  for (;;) {
    NSData *chunk = [fh readDataOfLength:1 << 20];
    if (!chunk.length) break;
    CC_SHA256_Update(&ctx, chunk.bytes, (CC_LONG)chunk.length);
  }
  [fh closeFile];
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256_Final(digest, &ctx);
  NSMutableString *hex = [NSMutableString stringWithCapacity:64];
  for (unsigned i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
  return hex;
}

static NSURLSession *Session(void) {
  NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.defaultSessionConfiguration;
  cfg.timeoutIntervalForRequest = 30;
  cfg.timeoutIntervalForResource = 3600;
  return [NSURLSession sessionWithConfiguration:cfg];
}

/* Blocking download with a progress callback four times a second. */
static NSString *Download(NSURLSession *session, NSURL *url, NSString *dest, void (^progress)(int64_t, int64_t)) {
  __block NSString *failure = nil;
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  NSURLSessionDownloadTask *task = [session downloadTaskWithURL:url
      completionHandler:^(NSURL *tmp, NSURLResponse *resp, NSError *err) {
        NSInteger code = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        if (err.code == NSURLErrorCancelled) failure = @"Cancelled";
        else if (err || !tmp) failure = err.localizedDescription ?: NSLocalizedString(@"download failed", nil);
        else if (code != 200) failure = [NSString stringWithFormat:NSLocalizedString(@"HTTP %ld for %@", nil), (long)code, url.lastPathComponent];
        else {
          [NSFileManager.defaultManager removeItemAtPath:dest error:nil];
          NSError *mv = nil;
          if (![NSFileManager.defaultManager moveItemAtURL:tmp toURL:[NSURL fileURLWithPath:dest] error:&mv])
            failure = mv.localizedDescription;
        }
        dispatch_semaphore_signal(done);
      }];
  g_task = task;
  [task resume];
  while (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC / 4))))
    if (progress) progress(task.countOfBytesReceived, task.countOfBytesExpectedToReceive);
  g_task = nil;
  return failure;
}

static NSString *WorkDir(NSString *docs) {
  return [docs stringByAppendingPathComponent:@"Apps/.steam-install"];
}

/* Fetches Valve's manifest into the work folder and reads it. */
static NSArray<NSDictionary *> *FetchManifest(NSURLSession *session, NSString *work, NSString **version, NSString **error) {
  [NSFileManager.defaultManager createDirectoryAtPath:work withIntermediateDirectories:YES attributes:nil error:nil];
  NSString *path = [work stringByAppendingPathComponent:IOSWINE_STEAM_MANIFEST];
  NSString *fail = Download(session, [NSURL URLWithString:[IOSWINE_STEAM_CLIENT_BASE stringByAppendingString:IOSWINE_STEAM_MANIFEST]], path, nil);
  if (fail) { *error = fail; return nil; }
  NSArray *packages = IOSWineSteamPackages([NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil], version);
  if (!packages) *error = NSLocalizedString(@"Couldn't read Steam's version list. Try again.", nil);
  return packages;
}

/* Steam's install index as it is built: one line per path. A path several
 * packages hold keeps the line of the package later in the manifest, as
 * Steam's updater does; unpacking in manifest order puts that package's copy
 * on disk too. */
struct unpack_report {
  void (^report)(double);
  NSMutableArray<NSString *> *paths;                      /* index paths, lower-cased, first seen first */
  NSMutableDictionary<NSString *, NSString *> *index;     /* path -> line */
  NSMutableDictionary<NSString *, NSNumber *> *folders;   /* folder on disk -> time, set last */
};

static int vz_unpacked(uint64_t done, uint64_t total, void *user) {
  struct unpack_report *r = user;
  if (total) r->report((double)done / (double)total);
  return g_cancel;
}

static int zip_unpacked(const char *entry, uint64_t done, uint64_t total, void *user) {
  struct unpack_report *r = user;
  (void)entry;
  if (total) r->report((double)done / (double)total);
  return g_cancel;
}

static void SetFileTime(const char *path, int64_t mtime) {
  struct timeval times[2] = { { (time_t)mtime, 0 }, { (time_t)mtime, 0 } };
  utimes(path, times);
}

/* Each extracted entry goes into Steam's install index, and its file gets the
 * time Steam's own extractor gives it. Folders are stamped at the end, once
 * nothing more is written into them. */
static int entry_unpacked(const zip_entry_info *e, void *user) {
  struct unpack_report *r = user;
  int64_t mtime = IOSWineSteamFileTime(e->dos_date, e->dos_time);
  NSString *name = [NSString stringWithUTF8String:e->name] ?: [NSString stringWithCString:e->name encoding:NSISOLatin1StringEncoding];
  NSString *line = IOSWineSteamIndexLine(name, e->is_dir, e->size, mtime, e->crc);
  NSString *key = [line substringToIndex:[line rangeOfString:@","].location].lowercaseString;
  if (!r->index[key]) [r->paths addObject:key];
  r->index[key] = line;
  if (e->is_dir) r->folders[@(e->path)] = @(mtime);
  else SetFileTime(e->path, mtime);
  return g_cancel;
}

/* Extracts one downloaded package into dest, adding its entries to the index. */
static NSString *Unpack(NSDictionary *package, NSString *archive, NSString *dest, struct unpack_report *index,
                        void (^report)(double)) {
  struct unpack_report r = { report, index->paths, index->index, index->folders };
  char err[256] = {0};
  if (package[@"vz"]) {
    if (vz_extract_ex(archive.fileSystemRepresentation, dest.fileSystemRepresentation, vz_unpacked, &r,
                      entry_unpacked, &r, err, sizeof err))
      return g_cancel ? @"Cancelled" : [NSString stringWithFormat:@"%@: %s", package[@"title"], err];
    return nil;
  }
  zip_reader *z = NULL;
  size_t skipped = 0;
  if (zip_open(archive.fileSystemRepresentation, &z, err, sizeof err))
    return [NSString stringWithFormat:@"%@: %s", package[@"title"], err];
  int rc = zip_extract_all_ex(z, dest.fileSystemRepresentation, zip_unpacked, &r, entry_unpacked, &r,
                              &skipped, err, sizeof err);
  zip_close(z);
  if (g_cancel) return @"Cancelled";
  if (rc) return [NSString stringWithFormat:@"%@: %s", package[@"title"], err];
  if (skipped) return [NSString stringWithFormat:NSLocalizedString(@"%@: %zu files could not be unpacked.", nil), package[@"title"], skipped];
  return nil;
}

@implementation WineSteamInstaller

+ (BOOL)isRunning { return g_running; }

+ (void)cancel {
  g_cancel = 1;
  [g_task cancel];
}

+ (void)fetchClientInto:(NSString *)docs
             completion:(void (^)(NSString *, NSArray<NSDictionary *> *, NSString *))completion {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSString *version = nil, *error = nil;
    NSArray *packages = FetchManifest(Session(), WorkDir(docs), &version, &error);
    dispatch_async(dispatch_get_main_queue(), ^{ completion(version, packages, error); });
  });
}

+ (void)installIntoDocuments:(NSString *)docs treeRoot:(NSString *)treeRoot
                    progress:(void (^)(WineSteamStep, NSUInteger, double, double))progress
                  completion:(void (^)(NSString *))completion {
  if (g_running) { completion(NSLocalizedString(@"An installation is already running.", nil)); return; }
  g_running = YES;
  g_cancel = 0;
  void (^report)(WineSteamStep, NSUInteger, double, double) = ^(WineSteamStep step, NSUInteger i, double fraction, double overall) {
    dispatch_async(dispatch_get_main_queue(), ^{ progress(step, i, fraction, overall); });
  };
  void (^finish)(NSString *) = ^(NSString *err) {
    g_running = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(err); });
  };
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *error = nil;
    NSString *steam = [docs stringByAppendingPathComponent:@"Apps/Steam"];
    if ([fm fileExistsAtPath:[steam stringByAppendingPathComponent:@"steam.exe"]]) { finish(NSLocalizedString(@"Steam is already installed.", nil)); return; }

    report(WineSteamStepPreparing, NSNotFound, 0, 0);
    NSString *bottle = IOSWineBottlePath(docs, @"Steam");
    if (![fm fileExistsAtPath:[bottle stringByAppendingPathComponent:@"system.reg"]] &&
        !IOSWineCreateBottle(docs, treeRoot, @"Steam", &error)) { finish(error); return; }
    if (!IOSWinePrepareSteamBottle(bottle, treeRoot, &error)) { finish(error); return; }

    NSURLSession *session = Session();
    NSString *work = WorkDir(docs);
    NSString *packages = [work stringByAppendingPathComponent:@"packages"];
    NSString *staging = [work stringByAppendingPathComponent:@"client"];
    NSString *manifestPath = [work stringByAppendingPathComponent:IOSWINE_STEAM_MANIFEST];
    [fm removeItemAtPath:staging error:nil];
    [fm createDirectoryAtPath:packages withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:staging withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *version = nil;
    NSArray *list = IOSWineSteamPackages([NSString stringWithContentsOfFile:manifestPath encoding:NSUTF8StringEncoding error:nil], &version)
                    ?: FetchManifest(session, work, &version, &error);
    if (!list) { finish(error); return; }
    if (g_cancel) { finish(@"Cancelled"); return; }

    /* Downloads weigh 4/5 of the bar, unpacking the rest. Everything is
     * downloaded first, then unpacked in manifest order (see unpack_report). */
    unsigned long long total = 0;
    for (NSDictionary *p in list) total += [p[@"downloadSize"] unsignedLongLongValue];
    __block double done = 0;
    double (^overall)(double) = ^double(double current) { return total ? (done + current) / (double)total : 0; };

    for (NSUInteger i = 0; i < list.count; i++) {
      NSDictionary *p = list[i];
      if (g_cancel) { finish(@"Cancelled"); return; }
      NSString *archive = [packages stringByAppendingPathComponent:p[@"download"]];
      unsigned long long size = [p[@"downloadSize"] unsignedLongLongValue];
      BOOL have = [[fm attributesOfItemAtPath:archive error:nil] fileSize] == size &&
                  [SHA256Hex(archive) isEqualToString:p[@"downloadSha2"]];
      if (!have) {
        NSString *fail = Download(session, [NSURL URLWithString:[IOSWINE_STEAM_CLIENT_BASE stringByAppendingString:p[@"download"]]], archive,
                                  ^(int64_t got, int64_t expected __unused) {
          double fraction = size ? MIN(1.0, (double)MAX(got, 0) / (double)size) : 1;
          report(WineSteamStepDownloading, i, fraction, overall(0.8 * fraction * size));
        });
        if (fail) { finish(fail); return; }
        if ([[fm attributesOfItemAtPath:archive error:nil] fileSize] != size || ![SHA256Hex(archive) isEqualToString:p[@"downloadSha2"]]) {
          [fm removeItemAtPath:archive error:nil];
          finish(NSLocalizedString(@"A download was damaged. Try again.", nil));
          return;
        }
      }
      done += 0.8 * size;
    }

    struct unpack_report index = { nil, [NSMutableArray array], [NSMutableDictionary dictionary], [NSMutableDictionary dictionary] };
    NSArray *byManifest = [list sortedArrayUsingDescriptors:@[ [NSSortDescriptor sortDescriptorWithKey:@"order" ascending:YES] ]];
    for (NSDictionary *p in byManifest) {
      if (g_cancel) { finish(@"Cancelled"); return; }
      NSUInteger i = [list indexOfObjectIdenticalTo:p];
      unsigned long long size = [p[@"downloadSize"] unsignedLongLongValue];
      NSString *fail = Unpack(p, [packages stringByAppendingPathComponent:p[@"download"]], staging, &index, ^(double fraction) {
        report(WineSteamStepUnpacking, i, fraction, overall(0.2 * fraction * size));
      });
      if (fail) { finish(fail); return; }
      done += 0.2 * size;
    }

    /* Steam's updater keeps three things in package/: every package under the
     * name it downloads it by, the manifest (steam_client_win64.manifest), and
     * an index of every installed file (steam_client_win64.installed). Its
     * first start verifies the install against that index; without it, it
     * reads the installed version as 0 and unpacks the whole client again,
     * under emulation. */
    report(WineSteamStepFinishing, list.count, 0, 1);
    NSString *packageDir = [staging stringByAppendingPathComponent:@"package"];
    [fm createDirectoryAtPath:packageDir withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSDictionary *p in list) {
      NSString *dest = [packageDir stringByAppendingPathComponent:p[@"download"]];
      [fm removeItemAtPath:dest error:nil];
      if (![fm moveItemAtPath:[packages stringByAppendingPathComponent:p[@"download"]] toPath:dest error:nil]) {
        finish(NSLocalizedString(@"Couldn't finish the install. Try again.", nil));
        return;
      }
    }
    NSData *manifest = [NSData dataWithContentsOfFile:manifestPath];
    NSString *saved = [packageDir stringByAppendingPathComponent:[IOSWINE_STEAM_MANIFEST stringByAppendingString:@".manifest"]];
    NSString *installed = [packageDir stringByAppendingPathComponent:[IOSWINE_STEAM_MANIFEST stringByAppendingString:@".installed"]];
    if (!manifest || ![IOSWineSteamSavedManifest(manifest) writeToFile:saved atomically:YES] ||
        ![IOSWineSteamInstalledIndex([index.index objectsForKeys:index.paths notFoundMarker:@""]) writeToFile:installed atomically:YES] ||
        ![fm fileExistsAtPath:[staging stringByAppendingPathComponent:@"steam.exe"]]) {
      finish(NSLocalizedString(@"The download was incomplete. Try again.", nil));
      return;
    }
    /* Last, the folders: extracting into them moved their times. */
    for (NSString *path in index.folders) SetFileTime(path.fileSystemRepresentation, index.folders[path].longLongValue);
    NSError *mv = nil;
    [fm removeItemAtPath:steam error:nil];
    if (![fm moveItemAtPath:staging toPath:steam error:&mv]) { finish(mv.localizedDescription); return; }
    [fm removeItemAtPath:work error:nil];
    finish(nil);
  });
}

@end

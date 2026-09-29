/* Removing what the app created: programs, bottles, caches, logs. */
#ifndef IOSWINE_RESET_H
#define IOSWINE_RESET_H

#import <Foundation/Foundation.h>

static inline unsigned long long IOSWineDirectorySize(NSString *path) {
  unsigned long long total = 0;
  NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtPath:path];
  for (NSString *sub in e) {
    NSDictionary *a = e.fileAttributes;
    if ([a.fileType isEqualToString:NSFileTypeRegular]) total += a.fileSize;
    (void)sub;
  }
  return total;
}

static inline void IOSWineClearLogs(NSString *docs) {
  NSFileManager *fm = NSFileManager.defaultManager;
  for (NSString *n in [fm contentsOfDirectoryAtPath:docs error:nil])
    if ([n hasPrefix:@"wine-stderr.log"] || [n isEqualToString:@"hb.log"] ||
        [n hasPrefix:@"launch-request.json.consumed-"] || [n hasPrefix:@"remote-input."])
      [fm removeItemAtPath:[docs stringByAppendingPathComponent:n] error:nil];
}

static inline BOOL IOSWineClearShaderCache(NSString *cacheRoot) {
  return [NSFileManager.defaultManager removeItemAtPath:cacheRoot error:nil];
}

/* Everything except the runtime tree (Documents/wine) and the settings. */
static inline void IOSWineRemoveEverything(NSString *docs, NSString *cacheRoot) {
  NSFileManager *fm = NSFileManager.defaultManager;
  for (NSString *n in @[ @"Apps", @"Bottles", @"prefix", @"launch-request.json", @"render-scale",
                         @"dxmt-gpu-debug.txt" ])
    [fm removeItemAtPath:[docs stringByAppendingPathComponent:n] error:nil];
  IOSWineClearLogs(docs);
  IOSWineClearShaderCache(cacheRoot);
}

#endif

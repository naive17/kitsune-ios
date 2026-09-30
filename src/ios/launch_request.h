/* One-shot launch requests (Documents/launch-request.json), from Play or pushed
 * from a Mac. No shell expansion or absolute paths. */
#ifndef KITSUNE_LAUNCH_REQUEST_H
#define KITSUNE_LAUNCH_REQUEST_H
#import <Foundation/Foundation.h>

static inline BOOL KitsuneBottleNameValid(id value) {
  if (![value isKindOfClass:NSString.class] || ![value length] || [value length] > 64)
    return NO;
  NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
      @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"];
  return [value rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

static inline NSDictionary *KitsuneValidateLaunchRequest(id json, NSString *docs, NSString **error) {
#define REJECT(why) do { if (error) *error = (why); return nil; } while (0)
  if (![json isKindOfClass:NSDictionary.class]) REJECT(NSLocalizedString(@"request must be a JSON object", nil));
  if (!KitsuneBottleNameValid(json[@"bottle"])) REJECT(NSLocalizedString(@"invalid bottle name", nil));
  id exe = json[@"exe"], args = json[@"args"] ?: @[];
  if (![exe isKindOfClass:NSString.class] || ![exe hasPrefix:@"Apps/"] ||
      [exe length] > 4096 || [exe containsString:@"\\"] ||
      [exe rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0]].location != NSNotFound)
    REJECT(NSLocalizedString(@"exe must be a relative path under Documents/Apps", nil));
  for (NSString *part in [exe componentsSeparatedByString:@"/"])
    if (!part.length || [part isEqualToString:@".."] || [part isEqualToString:@"."])
      REJECT(NSLocalizedString(@"invalid executable path component", nil));
  NSString *root = docs.stringByResolvingSymlinksInPath;
  NSString *full = [[docs stringByAppendingPathComponent:exe] stringByResolvingSymlinksInPath];
  if (![full hasPrefix:[root stringByAppendingString:@"/Apps/"]]) REJECT(NSLocalizedString(@"executable escapes Apps", nil));
  NSString *bottle = [[docs stringByAppendingPathComponent:
      [@"Bottles" stringByAppendingPathComponent:json[@"bottle"]]] stringByResolvingSymlinksInPath];
  NSString *expectedBottle = [root stringByAppendingPathComponent:
      [@"Bottles" stringByAppendingPathComponent:json[@"bottle"]]];
  if (![bottle isEqualToString:expectedBottle] ||
      [NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:
          [root stringByAppendingPathComponent:@"Bottles"] error:nil] ||
      [NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:expectedBottle error:nil])
    REJECT(NSLocalizedString(@"bottle path contains a symlink", nil));
  BOOL directory = NO;
  if (![NSFileManager.defaultManager fileExistsAtPath:full isDirectory:&directory] || directory)
    REJECT(NSLocalizedString(@"executable does not exist", nil));
  if (![args isKindOfClass:NSArray.class] || [args count] > 64) REJECT(NSLocalizedString(@"invalid argument array", nil));
  NSUInteger total = 0;
  for (id arg in args) {
    if (![arg isKindOfClass:NSString.class] ||
        [arg rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0]].location != NSNotFound)
      REJECT(NSLocalizedString(@"arguments must be strings without NUL bytes", nil));
    total += [arg lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (total > 16384) REJECT(NSLocalizedString(@"arguments exceed 16 KB", nil));
  }
  /* Optional per-launch environment, kept sane: names must look like env var
   * names (A-Z, 0-9, _), values are NUL-free and bounded. The host setenv's
   * each key before Wine starts, so any getenv() toggle in ntdll/wineios (e.g.
   * KITSUNE_FORCE_SWRAST, WINE_IOS_STACKPOOL_MB) is reachable for this launch
   * only. */
  NSDictionary *env = nil;
  if (json[@"env"] && json[@"env"] != NSNull.null) {
    id e = json[@"env"];
    if (![e isKindOfClass:NSDictionary.class] || [(NSDictionary *)e count] > 64)
      REJECT(NSLocalizedString(@"env must be a JSON object of at most 64 entries", nil));
    NSCharacterSet *nameOK = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"];
    for (id k in (NSDictionary *)e) {
      id v = ((NSDictionary *)e)[k];
      if (![k isKindOfClass:NSString.class] || ![k length] || [k length] > 128 ||
          [k rangeOfCharacterFromSet:nameOK.invertedSet].location != NSNotFound)
        REJECT(NSLocalizedString(@"env names must be [A-Za-z0-9_], 1-128 chars", nil));
      if (![v isKindOfClass:NSString.class] || [v length] > 4096 ||
          [v rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0]].location != NSNotFound)
        REJECT(NSLocalizedString(@"env values must be strings without NUL, <=4096 chars", nil));
    }
    env = e;
  }
  if (error) *error = nil;
  return @{ @"exe": full, @"args": args, @"bottle": json[@"bottle"], @"env": env ?: @{} };
#undef REJECT
}
#endif

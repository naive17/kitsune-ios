/*
 * Per-game configuration the launcher writes before a launch.
 *
 * Games keep their resolution in their own files and offer no way to pick it
 * from outside. For the titles listed here the launcher sets it to the
 * desktop size so the game fills the screen instead of a letterboxed 4:3.
 */
#ifndef IOSWINE_GAME_CONFIG_H
#define IOSWINE_GAME_CONFIG_H

#import <Foundation/Foundation.h>

/* Replace the resolution in a Dark Souls style GraphicsConfig.xml. Handles
 * both <Resolution-Width>N</Resolution-Width> and <Width>N</Width> inside a
 * <Resolution> element. Returns NO when neither form is present. */
static inline BOOL IOSWineRewriteGraphicsConfigXML(NSMutableString *xml, int width, int height) {
  NSError *err = nil;
  NSUInteger hits = 0;
  NSDictionary<NSString *, NSString *> *pairs = @{
    @"(<Resolution-Width>)\\s*\\d+\\s*(</Resolution-Width>)": [NSString stringWithFormat:@"$1%d$2", width],
    @"(<Resolution-Height>)\\s*\\d+\\s*(</Resolution-Height>)": [NSString stringWithFormat:@"$1%d$2", height],
    @"(<Resolution>\\s*<Width>)\\s*\\d+\\s*(</Width>)": [NSString stringWithFormat:@"$1%d$2", width],
    @"(<Width>\\s*\\d+\\s*</Width>\\s*<Height>)\\s*\\d+\\s*(</Height>)": [NSString stringWithFormat:@"$1%d$2", height],
  };
  for (NSString *pattern in pairs) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:&err];
    if (!re) return NO;
    hits += [re replaceMatchesInString:xml options:0 range:NSMakeRange(0, xml.length) withTemplate:pairs[pattern]];
  }
  return hits >= 2;
}

/* Find a file by name under `root`, at most `depth` levels down. */
static inline NSString *IOSWineFindFile(NSString *root, NSString *name, int depth) {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSString *direct = [root stringByAppendingPathComponent:name];
  if ([fm fileExistsAtPath:direct]) return direct;
  if (depth <= 0) return nil;
  for (NSString *entry in [fm contentsOfDirectoryAtPath:root error:nil]) {
    NSString *path = [root stringByAppendingPathComponent:entry];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir] || !isDir) continue;
    NSString *found = IOSWineFindFile(path, name, depth - 1);
    if (found) return found;
  }
  return nil;
}

/* Apply the desktop resolution to a known title. Returns the file changed,
 * or nil when the title is unknown or has no config yet (first run). */
static inline NSString *IOSWineApplyGameResolution(NSString *appID, NSString *bottleRoot, int width, int height) {
  if (width < 640 || height < 480) return nil;
  if ([appID isEqualToString:@"570940"]) {   /* DARK SOULS: REMASTERED */
    NSString *users = [bottleRoot stringByAppendingPathComponent:@"drive_c/users"];
    NSString *file = IOSWineFindFile(users, @"GraphicsConfig.xml", 5);
    if (!file || ![file containsString:@"DARK SOULS REMASTERED"]) return nil;
    NSMutableString *xml = [NSMutableString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil];
    if (!xml.length || !IOSWineRewriteGraphicsConfigXML(xml, width, height)) return nil;
    return [xml writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil] ? file : nil;
  }
  return nil;
}

#endif

/* The command lines programs run with: argument splitting, installers, and the
 * Wine tools a bottle offers. */
#ifndef KITSUNE_WINE_COMMAND_H
#define KITSUNE_WINE_COMMAND_H

#import <Foundation/Foundation.h>

/* Splits on spaces and tabs outside double quotes and drops the quotes. */
static inline NSArray<NSString *> *KitsuneSplitArguments(NSString *raw) {
  NSMutableArray<NSString *> *args = [NSMutableArray array];
  NSMutableString *cur = [NSMutableString string];
  BOOL quoted = NO, pending = NO;
  for (NSUInteger i = 0; i < raw.length; i++) {
    unichar c = [raw characterAtIndex:i];
    if (c == '"') { quoted = !quoted; pending = YES; continue; }
    if (!quoted && (c == ' ' || c == '\t' || c == '\n')) {
      if (pending) { [args addObject:[cur copy]]; [cur setString:@""]; pending = NO; }
      continue;
    }
    [cur appendFormat:@"%C", c];
    pending = YES;
  }
  if (pending) [args addObject:[cur copy]];
  return args;
}

/* A path on the phone as Windows sees it: every bottle maps Z: to the root. */
static inline NSString *KitsuneWindowsPath(NSString *path) {
  return [@"Z:" stringByAppendingString:[path stringByReplacingOccurrencesOfString:@"/" withString:@"\\"]];
}

/* One argument, quoted so CommandLineToArgvW reads it back unchanged. */
static inline NSString *KitsuneQuoteArgument(NSString *arg) {
  NSCharacterSet *special = [NSCharacterSet characterSetWithCharactersInString:@" \t\n\v\""];
  if (arg.length && [arg rangeOfCharacterFromSet:special].location == NSNotFound) return arg;
  NSMutableString *out = [NSMutableString stringWithString:@"\""];
  NSUInteger slashes = 0;
  for (NSUInteger i = 0; i < arg.length; i++) {
    unichar c = [arg characterAtIndex:i];
    if (c == '\\') { slashes++; continue; }
    /* Backslashes before a quote are escaped along with it; others stay literal. */
    NSUInteger n = c == '"' ? slashes * 2 + 1 : slashes;
    for (NSUInteger j = 0; j < n; j++) [out appendString:@"\\"];
    [out appendFormat:@"%C", c];
    slashes = 0;
  }
  for (NSUInteger j = 0; j < slashes * 2; j++) [out appendString:@"\\"];
  [out appendString:@"\""];
  return out;
}

/* The command line CreateProcess takes for argv, program first. The program
 * and any argument naming an existing file on the phone become Windows paths. */
static inline NSString *KitsuneWindowsCommandLine(NSArray<NSString *> *argv) {
  NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:argv.count];
  for (NSUInteger i = 0; i < argv.count; i++) {
    NSString *arg = argv[i];
    if ([arg hasPrefix:@"/"] && (i == 0 || [NSFileManager.defaultManager fileExistsAtPath:arg]))
      arg = KitsuneWindowsPath(arg);
    [parts addObject:KitsuneQuoteArgument(arg)];
  }
  return [parts componentsJoinedByString:@" "];
}

/* argv for an executable or a Windows Installer package; console programs run
 * without the display driver. */
static inline NSArray<NSString *> *KitsuneProgramArgv(NSString *path, NSString *arguments, BOOL console,
                                                      NSString *peDir, BOOL *gui) {
  if ([path.pathExtension.lowercaseString isEqualToString:@"msi"]) {
    *gui = YES;
    return @[ @"wine", [peDir stringByAppendingPathComponent:@"msiexec.exe"], @"/i", path ];
  }
  *gui = !console;
  return [@[ @"wine", path ] arrayByAddingObjectsFromArray:KitsuneSplitArguments(arguments ?: @"")];
}

typedef struct {
  const char *title, *symbol;
  const char *const argv[3];   /* program and arguments, NULL-terminated */
} KitsuneBottleTool;

static const KitsuneBottleTool kKitsuneBottleTools[] = {
  { "Wine Configuration", "gearshape", { "winecfg.exe", NULL } },
  { "Control Panel", "slider.horizontal.3", { "control.exe", NULL } },
  { "Registry Editor", "list.bullet.indent", { "regedit.exe", NULL } },
  { "Task Manager", "gauge.with.dots.needle.33percent", { "taskmgr.exe", NULL } },
  { "File Manager", "folder", { "winefile.exe", NULL } },
  { "Command Prompt", "terminal", { "wineconsole.exe", "cmd.exe", NULL } },
};
#define KITSUNE_BOTTLE_TOOL_COUNT (sizeof(kKitsuneBottleTools) / sizeof(kKitsuneBottleTools[0]))

static inline NSArray<NSString *> *KitsuneToolArgv(const KitsuneBottleTool *tool, NSString *peDir) {
  NSMutableArray<NSString *> *argv = [NSMutableArray arrayWithObjects:@"wine",
      [peDir stringByAppendingPathComponent:@(tool->argv[0])], nil];
  for (int i = 1; i < 3 && tool->argv[i]; i++) [argv addObject:@(tool->argv[i])];
  return argv;
}

#endif

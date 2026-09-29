/* The command lines programs run with: argument splitting, installers, and the
 * Wine tools a bottle offers. */
#ifndef IOSWINE_WINE_COMMAND_H
#define IOSWINE_WINE_COMMAND_H

#import <Foundation/Foundation.h>

/* Splits on spaces and tabs outside double quotes and drops the quotes. */
static inline NSArray<NSString *> *IOSWineSplitArguments(NSString *raw) {
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
static inline NSString *IOSWineWindowsPath(NSString *path) {
  return [@"Z:" stringByAppendingString:[path stringByReplacingOccurrencesOfString:@"/" withString:@"\\"]];
}

/* One argument, quoted so CommandLineToArgvW reads it back unchanged. */
static inline NSString *IOSWineQuoteArgument(NSString *arg) {
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
static inline NSString *IOSWineWindowsCommandLine(NSArray<NSString *> *argv) {
  NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:argv.count];
  for (NSUInteger i = 0; i < argv.count; i++) {
    NSString *arg = argv[i];
    if ([arg hasPrefix:@"/"] && (i == 0 || [NSFileManager.defaultManager fileExistsAtPath:arg]))
      arg = IOSWineWindowsPath(arg);
    [parts addObject:IOSWineQuoteArgument(arg)];
  }
  return [parts componentsJoinedByString:@" "];
}

/* argv for an executable or a Windows Installer package; console programs run
 * without the display driver. */
static inline NSArray<NSString *> *IOSWineProgramArgv(NSString *path, NSString *arguments, BOOL console,
                                                      NSString *peDir, BOOL *gui) {
  if ([path.pathExtension.lowercaseString isEqualToString:@"msi"]) {
    *gui = YES;
    return @[ @"wine", [peDir stringByAppendingPathComponent:@"msiexec.exe"], @"/i", path ];
  }
  *gui = !console;
  return [@[ @"wine", path ] arrayByAddingObjectsFromArray:IOSWineSplitArguments(arguments ?: @"")];
}

typedef struct {
  const char *title, *symbol;
  const char *const argv[3];   /* program and arguments, NULL-terminated */
} IOSWineBottleTool;

static const IOSWineBottleTool kIOSWineBottleTools[] = {
  { "Wine Configuration", "gearshape", { "winecfg.exe", NULL } },
  { "Control Panel", "slider.horizontal.3", { "control.exe", NULL } },
  { "Registry Editor", "list.bullet.indent", { "regedit.exe", NULL } },
  { "Task Manager", "gauge.with.dots.needle.33percent", { "taskmgr.exe", NULL } },
  { "File Manager", "folder", { "winefile.exe", NULL } },
  { "Command Prompt", "terminal", { "wineconsole.exe", "cmd.exe", NULL } },
};
#define IOSWINE_BOTTLE_TOOL_COUNT (sizeof(kIOSWineBottleTools) / sizeof(kIOSWineBottleTools[0]))

static inline NSArray<NSString *> *IOSWineToolArgv(const IOSWineBottleTool *tool, NSString *peDir) {
  NSMutableArray<NSString *> *argv = [NSMutableArray arrayWithObjects:@"wine",
      [peDir stringByAppendingPathComponent:@(tool->argv[0])], nil];
  for (int i = 1; i < 3 && tool->argv[i]; i++) [argv addObject:@(tool->argv[i])];
  return argv;
}

#endif

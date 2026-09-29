#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdio.h>
#include "../src/ios/wine_command.h"

int main(void) {
  @autoreleasepool {
    assert([IOSWineSplitArguments(@"") isEqualToArray:@[]]);
    assert([IOSWineSplitArguments(@"  -a\t-b  ") isEqualToArray:(@[ @"-a", @"-b" ])]);
    assert([IOSWineSplitArguments(@"-path \"C:\\Program Files\\x\" -w") isEqualToArray:(@[ @"-path", @"C:\\Program Files\\x", @"-w" ])]);
    assert([IOSWineSplitArguments(@"a\"b c\"d") isEqualToArray:(@[ @"ab cd" ])]);
    assert([IOSWineSplitArguments(@"x \"\" y") isEqualToArray:(@[ @"x", @"", @"y" ])]);

    BOOL gui = NO;
    NSArray *argv = IOSWineProgramArgv(@"/d/setup.MSI", @"ignored", NO, @"/pe", &gui);
    assert(gui && [argv isEqualToArray:(@[ @"wine", @"/pe/msiexec.exe", @"/i", @"/d/setup.MSI" ])]);
    argv = IOSWineProgramArgv(@"/d/tool.exe", @"-v \"a b\"", YES, @"/pe", &gui);
    assert(!gui && [argv isEqualToArray:(@[ @"wine", @"/d/tool.exe", @"-v", @"a b" ])]);
    argv = IOSWineProgramArgv(@"/d/game.exe", nil, NO, @"/pe", &gui);
    assert(gui && [argv isEqualToArray:(@[ @"wine", @"/d/game.exe" ])]);

    /* Windows command lines: CommandLineToArgvW's quoting rules, phone paths on Z:. */
    assert([IOSWineQuoteArgument(@"plain") isEqualToString:@"plain"]);
    assert([IOSWineQuoteArgument(@"") isEqualToString:@"\"\""]);
    assert([IOSWineQuoteArgument(@"two words") isEqualToString:@"\"two words\""]);
    assert([IOSWineQuoteArgument(@"say \"hi\"") isEqualToString:@"\"say \\\"hi\\\"\""]);
    assert([IOSWineQuoteArgument(@"C:\\dir with space\\") isEqualToString:@"\"C:\\dir with space\\\\\""]);
    assert([IOSWineQuoteArgument(@"a\\\\\"b") isEqualToString:@"\"a\\\\\\\\\\\"b\""]);
    assert([IOSWineWindowsPath(@"/var/mobile/Apps/Steam/steam.exe") isEqualToString:@"Z:\\var\\mobile\\Apps\\Steam\\steam.exe"]);
    NSString *tmp = NSTemporaryDirectory();
    NSString *line = IOSWineWindowsCommandLine(@[ @"/Apps/My Game/game.exe", @"/i", tmp, @"-applaunch", @"440" ]);
    NSString *want = [NSString stringWithFormat:@"\"Z:\\Apps\\My Game\\game.exe\" /i %@ -applaunch 440",
                                                IOSWineQuoteArgument(IOSWineWindowsPath(tmp))];
    assert([line isEqualToString:want]);

    assert(IOSWINE_BOTTLE_TOOL_COUNT == 6);
    for (size_t i = 0; i < IOSWINE_BOTTLE_TOOL_COUNT; i++) {
      const IOSWineBottleTool *t = &kIOSWineBottleTools[i];
      assert(t->title && t->symbol && t->argv[0]);
      argv = IOSWineToolArgv(t, @"/pe");
      assert([argv[0] isEqualToString:@"wine"] && [argv[1] hasPrefix:@"/pe/"] && [argv[1] hasSuffix:@".exe"]);
    }
    assert([IOSWineToolArgv(&kIOSWineBottleTools[5], @"/pe") isEqualToArray:(@[ @"wine", @"/pe/wineconsole.exe", @"cmd.exe" ])]);
    puts("WINE COMMAND PASS: quoting, empty quoted arguments, Windows command lines, installers, console programs, bottle tools");
  }
}

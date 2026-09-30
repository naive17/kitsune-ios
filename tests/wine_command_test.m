#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdio.h>
#include "../src/ios/wine_command.h"

int main(void) {
  @autoreleasepool {
    assert([KitsuneSplitArguments(@"") isEqualToArray:@[]]);
    assert([KitsuneSplitArguments(@"  -a\t-b  ") isEqualToArray:(@[ @"-a", @"-b" ])]);
    assert([KitsuneSplitArguments(@"-path \"C:\\Program Files\\x\" -w") isEqualToArray:(@[ @"-path", @"C:\\Program Files\\x", @"-w" ])]);
    assert([KitsuneSplitArguments(@"a\"b c\"d") isEqualToArray:(@[ @"ab cd" ])]);
    assert([KitsuneSplitArguments(@"x \"\" y") isEqualToArray:(@[ @"x", @"", @"y" ])]);

    BOOL gui = NO;
    NSArray *argv = KitsuneProgramArgv(@"/d/setup.MSI", @"ignored", NO, @"/pe", &gui);
    assert(gui && [argv isEqualToArray:(@[ @"wine", @"/pe/msiexec.exe", @"/i", @"/d/setup.MSI" ])]);
    argv = KitsuneProgramArgv(@"/d/tool.exe", @"-v \"a b\"", YES, @"/pe", &gui);
    assert(!gui && [argv isEqualToArray:(@[ @"wine", @"/d/tool.exe", @"-v", @"a b" ])]);
    argv = KitsuneProgramArgv(@"/d/game.exe", nil, NO, @"/pe", &gui);
    assert(gui && [argv isEqualToArray:(@[ @"wine", @"/d/game.exe" ])]);

    /* Windows command lines: CommandLineToArgvW's quoting rules, phone paths on Z:. */
    assert([KitsuneQuoteArgument(@"plain") isEqualToString:@"plain"]);
    assert([KitsuneQuoteArgument(@"") isEqualToString:@"\"\""]);
    assert([KitsuneQuoteArgument(@"two words") isEqualToString:@"\"two words\""]);
    assert([KitsuneQuoteArgument(@"say \"hi\"") isEqualToString:@"\"say \\\"hi\\\"\""]);
    assert([KitsuneQuoteArgument(@"C:\\dir with space\\") isEqualToString:@"\"C:\\dir with space\\\\\""]);
    assert([KitsuneQuoteArgument(@"a\\\\\"b") isEqualToString:@"\"a\\\\\\\\\\\"b\""]);
    assert([KitsuneWindowsPath(@"/var/mobile/Apps/Steam/steam.exe") isEqualToString:@"Z:\\var\\mobile\\Apps\\Steam\\steam.exe"]);
    NSString *tmp = NSTemporaryDirectory();
    NSString *line = KitsuneWindowsCommandLine(@[ @"/Apps/My Game/game.exe", @"/i", tmp, @"-applaunch", @"440" ]);
    NSString *want = [NSString stringWithFormat:@"\"Z:\\Apps\\My Game\\game.exe\" /i %@ -applaunch 440",
                                                KitsuneQuoteArgument(KitsuneWindowsPath(tmp))];
    assert([line isEqualToString:want]);

    assert(KITSUNE_BOTTLE_TOOL_COUNT == 6);
    for (size_t i = 0; i < KITSUNE_BOTTLE_TOOL_COUNT; i++) {
      const KitsuneBottleTool *t = &kKitsuneBottleTools[i];
      assert(t->title && t->symbol && t->argv[0]);
      argv = KitsuneToolArgv(t, @"/pe");
      assert([argv[0] isEqualToString:@"wine"] && [argv[1] hasPrefix:@"/pe/"] && [argv[1] hasSuffix:@".exe"]);
    }
    assert([KitsuneToolArgv(&kKitsuneBottleTools[5], @"/pe") isEqualToArray:(@[ @"wine", @"/pe/wineconsole.exe", @"cmd.exe" ])]);
    puts("WINE COMMAND PASS: quoting, empty quoted arguments, Windows command lines, installers, console programs, bottle tools");
  }
}

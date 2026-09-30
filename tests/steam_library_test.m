#import "../src/ios/steam_library.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
  @autoreleasepool {
    NSDictionary *kv = KitsuneParseKeyValues(
        @"\"AppState\"\n{\n\t\"appid\"\t\t\"570940\"\n\t\"name\"\t\t\"DARK SOULS\\u2122: REMASTERED\"\n"
         "\t\"StateFlags\"\t\t\"4\"\n\t\"installdir\"\t\t\"DARK SOULS REMASTERED\"\n"
         "\t\"SizeOnDisk\"\t\t\"7876543210\"\n\t\"UserConfig\"\n\t{\n\t\t\"language\"\t\t\"english\"\n\t}\n"
         "\t// a comment\n\t\"esc\"\t\"a\\\"b\\\\c\\n\"\n\t\"InstalledDepots\"\n\t{\n\t\t\"570941\"\n\t\t{\n\t\t\t\"manifest\"\t\t\"1\"\n\t\t}\n\t}\n}\n");
    assert(kv && [kv[@"appid"] isEqualToString:@"570940"]);
    assert([kv[@"installdir"] isEqualToString:@"DARK SOULS REMASTERED"]);
    assert([kv[@"UserConfig"][@"language"] isEqualToString:@"english"]);
    assert([kv[@"InstalledDepots"][@"570941"][@"manifest"] isEqualToString:@"1"]);
    assert([kv[@"esc"] isEqualToString:@"a\"b\\c\n"]);
    assert(!KitsuneParseKeyValues(@"\"A\" { \"k\" "));       /* unterminated */
    assert(!KitsuneParseKeyValues(@"\"A\" { \"k\" \"v\" } }")); /* extra brace */
    assert(!KitsuneParseKeyValues(@"{ \"k\" \"v\" }"));        /* brace without key */
    assert(!KitsuneParseKeyValues(@""));
    assert(!KitsuneParseKeyValues(nil));

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *docs = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"steam-library-test-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *apps = [docs stringByAppendingPathComponent:@"Apps/Steam/steamapps"];
    assert(!KitsuneSteamRoot(docs));
    assert([fm createDirectoryAtPath:[apps stringByAppendingPathComponent:@"common/DARK SOULS REMASTERED"]
                withIntermediateDirectories:YES attributes:nil error:nil]);
    assert([fm createDirectoryAtPath:[apps stringByAppendingPathComponent:@"common/Half-Life"]
                withIntermediateDirectories:YES attributes:nil error:nil]);
    assert([@"stub" writeToFile:[docs stringByAppendingPathComponent:@"Apps/Steam/steam.exe"]
                     atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    NSString *root = KitsuneSteamRoot(docs);
    assert([root hasSuffix:@"Apps/Steam"]);
    NSString *(^acf)(NSString *, NSString *, NSString *, NSString *) = ^(NSString *id_, NSString *name, NSString *dir, NSString *flags) {
      return [NSString stringWithFormat:@"\"AppState\"\n{\n\t\"appid\"\t\"%@\"\n\t\"name\"\t\"%@\"\n\t\"StateFlags\"\t\"%@\"\n\t\"installdir\"\t\"%@\"\n\t\"SizeOnDisk\"\t\"123\"\n}\n", id_, name, flags, dir];
    };
    assert([acf(@"570940", @"DARK SOULS: REMASTERED", @"DARK SOULS REMASTERED", @"4")
        writeToFile:[apps stringByAppendingPathComponent:@"appmanifest_570940.acf"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    assert([acf(@"70", @"Half-Life", @"Half-Life", @"1026")   /* downloading, not installed */
        writeToFile:[apps stringByAppendingPathComponent:@"appmanifest_70.acf"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    assert([acf(@"220", @"Gone", @"Missing Dir", @"4")           /* manifest without files */
        writeToFile:[apps stringByAppendingPathComponent:@"appmanifest_220.acf"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    assert([acf(@"9x9", @"Bad id", @"Half-Life", @"4")
        writeToFile:[apps stringByAppendingPathComponent:@"appmanifest_bad.acf"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    assert([acf(@"1", @"Escapes", @"../Half-Life", @"4")
        writeToFile:[apps stringByAppendingPathComponent:@"appmanifest_1.acf"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    assert([@"not keyvalues {" writeToFile:[apps stringByAppendingPathComponent:@"appmanifest_2.acf"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    NSArray *games = KitsuneSteamGames(root);
    assert(games.count == 2);
    assert([games[0][@"name"] isEqualToString:@"DARK SOULS: REMASTERED"] && [games[0][@"installed"] boolValue]);
    assert([games[0][@"path"] hasSuffix:@"steamapps/common/DARK SOULS REMASTERED"]);
    assert([games[0][@"appid"] isEqualToString:@"570940"] && [games[0][@"size"] unsignedLongLongValue] == 123);
    assert([games[1][@"name"] isEqualToString:@"Half-Life"] && ![games[1][@"installed"] boolValue]);
    assert([fm removeItemAtPath:docs error:nil]);
    puts("STEAM LIBRARY PASS: KeyValues subset, malformed files skipped, install state and directory checks, sorted");
  }
}

#import "../src/ios/steam_install.h"
#import "../src/ios/reset.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
  @autoreleasepool {
    NSString *manifest =
        @"\"win64\"\n{\n\t\"version\"\t\t\"1758000000\"\n\t\"bins_win64\"\n\t{\n\t\t\"file\"\t\t\"bins_win64_a1b2.zip.abc\"\n"
         "\t\t\"size\"\t\t\"12345\"\n\t\t\"sha2\"\t\t\"" "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" "\"\n"
         "\t\t\"zipvz\"\t\t\"bins_win64.zip.vz.a1b2_9000\"\n\t\t\"sha2vz\"\t\t\"" "abababababababababababababababababababababababababababababababab" "\"\n\t}\n"
         "\t\"steam_win64\"\n\t{\n\t\t\"file\"\t\t\"steam_win64_c3d4.zip.def\"\n\t\t\"size\"\t\t\"99\"\n\t\t\"sha2\"\t\t\""
         "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210" "\"\n\t}\n\t\"note\"\t\t\"x\"\n}\n";
    NSString *version = nil;
    NSArray *pk = KitsuneSteamPackages(manifest, &version);
    assert(pk.count == 2 && [version isEqualToString:@"1758000000"]);
    /* Largest download first; a package with a VZ copy downloads the VZ. */
    assert([pk[0][@"name"] isEqualToString:@"bins_win64"] && [pk[0][@"title"] isEqualToString:@"Steam client"]);
    assert([pk[0][@"file"] isEqualToString:@"bins_win64_a1b2.zip.abc"] && [pk[0][@"size"] unsignedLongLongValue] == 12345);
    assert([pk[0][@"download"] isEqualToString:@"bins_win64.zip.vz.a1b2_9000"] && [pk[0][@"downloadSize"] unsignedLongLongValue] == 9000);
    assert([pk[0][@"downloadSha2"] hasPrefix:@"abab"] && [pk[0][@"vz"] isEqualToString:pk[0][@"download"]]);
    assert(!pk[1][@"vz"] && [pk[1][@"download"] isEqualToString:@"steam_win64_c3d4.zip.def"] && [pk[1][@"downloadSize"] unsignedLongLongValue] == 99);
    assert([pk[1][@"title"] isEqualToString:@"Steam launcher"] && [KitsuneSteamPackageTitle(@"new_pkg") isEqualToString:@"new_pkg"]);
    assert(!KitsuneSteamPackages([manifest stringByReplacingOccurrencesOfString:@"zip.def" withString:@"zip/../x"], nil));
    assert(!KitsuneSteamPackages([manifest stringByReplacingOccurrencesOfString:@"fedcba98" withString:@"FEDCBA98"], nil));
    assert(!KitsuneSteamPackages([manifest stringByReplacingOccurrencesOfString:@"a1b2_9000" withString:@"a1b2_90x0"], nil));
    assert(!KitsuneSteamPackages([manifest stringByReplacingOccurrencesOfString:@"\t\t\"sha2vz\"" withString:@"\t\t\"other\""], nil));
    assert(!KitsuneSteamPackages(@"\"win64\" { \"version\" \"1\" }", nil));
    assert(!KitsuneSteamPackages(@"garbage {", nil));

    /* The launcher package has realm variants beside its generic names; the
     * updater checks steamrow's. */
    NSString *sha = @"1111111111111111111111111111111111111111111111111111111111111111";
    NSString *(^variant)(NSString *) = ^NSString *(NSString *stem) {
      return [NSString stringWithFormat:@"{ \"file\" \"%@.zip.abc\" \"size\" \"99\" \"sha2\" \"%@\" "
                                         "\"zipvz\" \"%@.zip.vz.abc_80\" \"sha2vz\" \"%@\" }", stem, sha, stem, sha];
    };
    NSString *realms = [NSString stringWithFormat:@"\"win64\" { \"version\" \"1\" \"steam_win64\" { "
                        "\"file\" \"steam_win64.zip.abc\" \"size\" \"99\" \"sha2\" \"%@\" \"zipvz\" \"steam_win64.zip.vz.abc_80\" "
                        "\"sha2vz\" \"%@\" \"steamrow\" %@ \"steamchina\" %@ } }",
                        sha, sha, variant(@"steam_win64_steamrow"), variant(@"steam_win64_steamchina")];
    NSData *(^bytes)(const char *) = ^NSData *(const char *str) { return [NSData dataWithBytes:str length:strlen(str)]; };
    /* package/steam_client_win64.manifest: the server's manifest with CRLF. */
    assert([KitsuneSteamSavedManifest(bytes("\"win64\"\n{\n}\n")) isEqualToData:bytes("\"win64\"\r\n{\r\n}\r\n")]);
    assert([KitsuneSteamSavedManifest(bytes("a\r\nb\n")) isEqualToData:bytes("a\r\nb\r\n")]);
    assert(KitsuneSteamSavedManifest([NSData data]).length == 0);

    /* package/steam_client_win64.installed, against lines of an index Steam's
     * updater wrote itself: the zip's DOS time read as UTC plus eight hours,
     * CRC-32 unsigned, folders with -1, then the footer and its SHA-1. */
    assert(KitsuneSteamFileTime(23724, 20597) == 1778609022);   /* 2026-05-12 10:03:42 */
    assert(KitsuneSteamFileTime(22094, 2903) == 1676366806);    /* 2023-02-14 01:26:46 */
    assert([KitsuneSteamIndexLine(@"bin/hardwareupdater/hardwareupdater.exe", NO, 8718056, 1778609022, 3829382378u)
               isEqualToString:@"bin\\hardwareupdater\\hardwareupdater.exe,8718056;1778609022;3829382378"]);
    assert([KitsuneSteamIndexLine(@"bin/hardwareupdater/", YES, 0, 1778609022, 0) isEqualToString:@"bin\\hardwareupdater\\,-1;1778609022;0"]);
    assert([KitsuneSteamIndexLine(@"bin", YES, 0, 5, 0) isEqualToString:@"bin\\,-1;5;0"]);
    assert([KitsuneSteamInstalledIndex(@[ @"a.dll,3;5;7", @"bin\\,-1;5;0" ])
               isEqualToData:bytes("a.dll,3;5;7\r\nbin\\,-1;5;0\r\nOSVER=16\r\nVERSION=3\r\n"
                                   "SHA1=9F74BAC24C887C4147973B1A92402F734CCDDE22\r\n")]);
    /* Between two packages holding one path, the later in the manifest wins. */
    assert([pk[1][@"order"] unsignedIntegerValue] > [pk[0][@"order"] unsignedIntegerValue]);

    pk = KitsuneSteamPackages(realms, nil);
    assert(pk.count == 1 && [pk[0][@"name"] isEqualToString:@"steam_win64"]);
    assert([pk[0][@"download"] isEqualToString:@"steam_win64_steamrow.zip.vz.abc_80"] &&
           [pk[0][@"file"] isEqualToString:@"steam_win64_steamrow.zip.abc"]);

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"steam-install-test-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *docs = [base stringByAppendingPathComponent:@"Documents"];
    NSString *tree = [base stringByAppendingPathComponent:@"tree"];
    NSString *pe = [tree stringByAppendingPathComponent:@"lib/wine/aarch64-windows"];
    NSString *tmpl = [tree stringByAppendingPathComponent:@"prefix-template"];
    assert([fm createDirectoryAtPath:pe withIntermediateDirectories:YES attributes:nil error:nil]);
    assert([fm createDirectoryAtPath:[tmpl stringByAppendingPathComponent:@"drive_c/windows"] withIntermediateDirectories:YES attributes:nil error:nil]);
    assert([@"WINE REGISTRY Version 2\n;; All keys relative to \\\\Machine\n\n[Software\\\\Classes] 1\n\"x\"=\"y\"\n"
        writeToFile:[tmpl stringByAppendingPathComponent:@"system.reg"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    assert([@"WINE REGISTRY Version 2\n;; All keys relative to \\\\User\\\\S-1-5-21-0-0-0-1000\n\n[Software\\\\Wine\\\\Fonts] 1\n"
        writeToFile:[tmpl stringByAppendingPathComponent:@"user.reg"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    assert([@"v1" writeToFile:[tree stringByAppendingPathComponent:@"TREE_VERSION"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    assert([fm createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:nil]);
    NSString *error = nil;
    assert(KitsuneCreateBottle(docs, tree, @"Steam", &error));
    NSString *bottle = KitsuneBottlePath(docs, @"Steam");
    assert(!KitsunePrepareSteamBottle(bottle, tree, &error) && [error containsString:@"comctl32_v6.dll"]);
    assert([@"MZv6" writeToFile:[pe stringByAppendingPathComponent:@"comctl32_v6.dll"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    assert([@"MZrsa" writeToFile:[pe stringByAppendingPathComponent:@"rsaenh.dll"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    assert(KitsunePrepareSteamBottle(bottle, tree, &error) && !error);
    assert(KitsunePrepareSteamBottle(bottle, tree, &error));   /* idempotent */
    NSString *sys = [NSString stringWithContentsOfFile:[bottle stringByAppendingPathComponent:@"system.reg"] encoding:NSUTF8StringEncoding error:nil];
    assert([sys componentsSeparatedByString:@"Microsoft Enhanced RSA and AES Cryptographic Provider]"].count == 2);
    assert([sys containsString:@"\"Image Path\"=\"C:\\\\windows\\\\system32\\\\rsaenh.dll\""] && [sys hasPrefix:@"WINE REGISTRY Version 2"]);
    NSString *usr = [NSString stringWithContentsOfFile:[bottle stringByAppendingPathComponent:@"user.reg"] encoding:NSUTF8StringEncoding error:nil];
    assert([usr componentsSeparatedByString:@"\"Version\"=\"win10\""].count == 2 && [usr containsString:@"[Software\\\\Wine] "]);
    NSString *sxs = [bottle stringByAppendingPathComponent:@"drive_c/windows/winsxs"];
    NSString *man = [NSString stringWithContentsOfFile:[sxs stringByAppendingPathComponent:
        [@"manifests/" stringByAppendingString:[KITSUNE_COMCTL_ASSEMBLY stringByAppendingString:@".manifest"]]] encoding:NSUTF8StringEncoding error:nil];
    assert([man containsString:@"processorArchitecture=\"arm64\""] && [man containsString:@"version=\"6.0.2600.2982\""]);
    assert([[NSString stringWithContentsOfFile:[[sxs stringByAppendingPathComponent:KITSUNE_COMCTL_ASSEMBLY] stringByAppendingPathComponent:@"comctl32.dll"]
        encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"MZv6"]);
    assert([[NSString stringWithContentsOfFile:[bottle stringByAppendingPathComponent:@"drive_c/windows/system32/rsaenh.dll"]
        encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"MZrsa"]);

    /* Reset removes what the app made and leaves the runtime tree. */
    NSString *cache = [base stringByAppendingPathComponent:@"Caches/dxmt"];
    assert([fm createDirectoryAtPath:[docs stringByAppendingPathComponent:@"Apps/Steam"] withIntermediateDirectories:YES attributes:nil error:nil]);
    assert([fm createDirectoryAtPath:[docs stringByAppendingPathComponent:@"wine/lib"] withIntermediateDirectories:YES attributes:nil error:nil]);
    assert([fm createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil]);
    for (NSString *n in @[ @"hb.log", @"wine-stderr.log", @"wine-stderr.log.previous-1", @"launch-request.json.consumed-2", @"render-scale" ])
      assert([@"x" writeToFile:[docs stringByAppendingPathComponent:n] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    assert([@"shader" writeToFile:[cache stringByAppendingPathComponent:@"db"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    assert(KitsuneDirectorySize(cache) == 6);
    KitsuneRemoveEverything(docs, cache);
    assert(![fm fileExistsAtPath:[docs stringByAppendingPathComponent:@"Apps"]] && ![fm fileExistsAtPath:[docs stringByAppendingPathComponent:@"Bottles"]]);
    assert(![fm fileExistsAtPath:[docs stringByAppendingPathComponent:@"hb.log"]] && ![fm fileExistsAtPath:[docs stringByAppendingPathComponent:@"render-scale"]]);
    assert(![fm fileExistsAtPath:cache]);
    assert([fm fileExistsAtPath:[docs stringByAppendingPathComponent:@"wine/lib"]]);
    assert([fm removeItemAtPath:base error:nil]);
    puts("STEAM INSTALL PASS: manifest packages validated (VZ copies, steamrow launcher, manifest order), saved manifest and install index as Steam writes them, bottle prepared idempotently (win10, sxs, rsaenh), reset keeps the runtime");
  }
}

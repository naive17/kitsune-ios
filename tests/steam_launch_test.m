#import "../src/ios/steam_launch.h"
#import "../src/ios/launcher_settings.h"
#include <assert.h>
#include <stdio.h>

static NSString *Query(NSURL *url, NSString *name) {
  for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].queryItems)
    if ([item.name isEqualToString:name]) return item.value;
  return nil;
}

int main(void) {
  @autoreleasepool {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *docs = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"steam-launch-test-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *apps = [docs stringByAppendingPathComponent:@"Apps/Steam/steamapps"];
    NSString *dir = [apps stringByAppendingPathComponent:@"common/DARK SOULS REMASTERED"];
    assert([fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil]);
    assert([fm createDirectoryAtPath:[docs stringByAppendingPathComponent:@"Bottles/Steam"] withIntermediateDirectories:YES attributes:nil error:nil]);
    KitsuneLaunchOptions o = KitsuneDefaultLaunchOptions();
    NSString *error = nil;
    assert(!KitsuneSteamRequest(nil, o, docs, &error) && [error containsString:@"Steam is not installed"]);
    assert([@"stub" writeToFile:[docs stringByAppendingPathComponent:@"Apps/Steam/steam.exe"]
        atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    assert(!KitsuneSteamRequest(@"570940", o, docs, &error) && [error containsString:@"not installed"]);
    NSString *acf = @"\"AppState\"\n{\n\"appid\" \"570940\"\n\"name\" \"DARK SOULS: REMASTERED\"\n\"StateFlags\" \"1026\"\n\"installdir\" \"DARK SOULS REMASTERED\"\n}\n";
    assert([acf writeToFile:[apps stringByAppendingPathComponent:@"appmanifest_570940.acf"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    assert(!KitsuneSteamRequest(@"570940", o, docs, &error) && [error containsString:@"not fully installed"]);
    acf = [acf stringByReplacingOccurrencesOfString:@"\"1026\"" withString:@"\"4\""];
    assert([acf writeToFile:[apps stringByAppendingPathComponent:@"appmanifest_570940.acf"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);

    /* Play mode: Steam hidden whatever the setting, no debug env, tested memory policy. */
    NSDictionary *request = KitsuneSteamRequest(@"570940", o, docs, &error);
    assert(request && !error);
    assert([request[@"bottle"] isEqualToString:@"Steam"]);
    assert(o.steamVisible && ([request[@"args"] isEqual:@[@"-silent", @"-applaunch", @"570940"]]));
    NSDictionary *env = request[@"env"];
    assert([env[@"DXMT_CONFIG"] isEqualToString:@"d3d11.mipClampBC = 4; d3d11.bcMaxDim = 512"]);
    assert([env[@"KITSUNE_BC_16BIT"] isEqualToString:@"1"] && !env[@"KITSUNE_BC_NATIVE"]);
    assert([env[@"KITSUNE_ARENA_CODE_MB"] isEqualToString:@"384"] && [env[@"WINE_IOS_BIGPOOL_MB"] isEqualToString:@"1"]);
    assert([env[@"WINE_IOS_CEF_LOWBAND"] isEqualToString:@"1"] && [env[@"KITSUNE_FORCE_SWRAST"] isEqualToString:@"1"]);
    assert([env[@"KITSUNE_GAME_INPUT"] isEqualToString:@"1"] && [env[@"WINEDLLOVERRIDES"] containsString:@"xinput1_4"]);
    assert([env[@"KITSUNE_LANDSCAPE"] isEqualToString:@"1"] && !env[@"KITSUNE_SCREEN_MAX"]);
    assert([env[@"KITSUNE_STEAM_LEAN"] isEqualToString:@"1"]);
    assert([env[@"KITSUNE_RGBA_ETC2"] isEqualToString:@"1"]);   /* large RGBA8 atlases stored as ETC2 */
    assert(!env[@"KITSUNE_THREAD_DUMP"] && !env[@"WINEIOS_METAL_DEBUG"] && !env[@"KITSUNE_XINPUT_TRACE"] && !env[@"KITSUNE_TRACE_BIGALLOC"]);

    /* The client alone, visible, with full diagnostics: no -console, which
     * starts this Steam with its window hidden. */
    {
      KitsuneLaunchOptions v = KitsuneDefaultLaunchOptions();
      v.console = YES; v.diag = KitsuneDiagFull;
      NSDictionary *visible = KitsuneSteamLaunchRequest(nil, v);
      assert([visible[@"args"] isEqual:@[]]);
    }
    /* The client alone, hidden, with the console and full diagnostics. */
    o.steamVisible = NO; o.console = YES; o.diag = KitsuneDiagFull; o.frameCap = 30;
    o.textures = KitsuneTexturesNative;
    request = KitsuneSteamRequest(nil, o, docs, &error);
    assert(request && ([request[@"args"] isEqual:@[@"-console", @"-silent"]]));
    env = request[@"env"];
    assert([env[@"DXMT_CONFIG"] isEqualToString:@"d3d11.mipClampBC = 0; d3d11.preferredMaxFrameRate = 30"]);
    assert([env[@"KITSUNE_BC_NATIVE"] isEqualToString:@"1"] && !env[@"KITSUNE_BC_16BIT"]);
    assert([env[@"KITSUNE_THREAD_DUMP"] isEqualToString:@"5"] && [env[@"WINEIOS_METAL_DEBUG"] isEqualToString:@"1"]);
    assert(!env[@"KITSUNE_STEAM_LEAN"]);   /* the client alone keeps its UI */
    o.textures = KitsuneTexturesDownscaled1024; o.frameCap = 0;
    assert([KitsuneDXMTConfig(o.textures, o.frameCap) isEqualToString:@"d3d11.mipClampBC = 4; d3d11.bcMaxDim = 1024"]);

    /* The JSON written to Documents parses back into a valid request. */
    NSData *data = KitsuneSteamRequestData(@"570940", KitsuneDefaultLaunchOptions());
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    assert(KitsuneValidateLaunchRequest(json, docs, &error) && !error);

    /* Settings -> options. */
    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:@"kitsune-launch-test"];
    [ud removePersistentDomainForName:@"kitsune-launch-test"];
    KitsuneLaunchOptions s = KitsuneLaunchOptionsFromSettings(ud);
    assert(s.steamVisible && !s.console && s.diag == KitsuneDiagOff && s.textures == KitsuneTexturesDownscaled512 && s.frameCap == 0 && s.landscape);
    [ud setInteger:60 forKey:KITSUNE_KEY_FRAME_CAP];
    [ud setInteger:KitsuneTexturesNative forKey:KITSUNE_KEY_TEXTURES];
    [ud setBool:NO forKey:KITSUNE_KEY_STEAM_VISIBLE];
    KitsuneDiagStore(ud, KitsuneDiagFull);
    s = KitsuneLaunchOptionsFromSettings(ud);
    assert(!s.steamVisible && s.console && s.diag == KitsuneDiagFull && s.textures == KitsuneTexturesNative && s.frameCap == 60);
    [ud setInteger:45 forKey:KITSUNE_KEY_FRAME_CAP];
    assert(KitsuneFrameCapStored(ud) == 0);
    [ud setInteger:99 forKey:KITSUNE_KEY_TEXTURES];
    assert(KitsuneTextureModeStored(ud) == KitsuneTexturesDownscaled512);
    assert(KitsuneSafeAreaStored(ud));
    /* Pointer mode: trackpad until one is chosen; a choice, touch included, is kept. */
    assert(KitsunePointerModeStored(ud) == 1);
    [ud setInteger:0 forKey:KITSUNE_KEY_POINTER_MODE];
    assert(KitsunePointerModeStored(ud) == 0);
    [ud setInteger:2 forKey:KITSUNE_KEY_POINTER_MODE];
    assert(KitsunePointerModeStored(ud) == 2);
    [ud setInteger:7 forKey:KITSUNE_KEY_POINTER_MODE];
    assert(KitsunePointerModeStored(ud) == 1);
    [ud removePersistentDomainForName:@"kitsune-launch-test"];

    /* Minimum scale: 800x600 must fit the safe-area desktop on both axes. */
    assert(KitsuneMinimumScaleForPoints(844, 390) == 1.6);   /* full glass, iPhone 14 */
    assert(KitsuneMinimumScaleForPoints(750, 369) == 1.7);   /* safe area, iPhone 14: 600/369 = 1.626 */
    assert(KitsuneMinimumScaleForPoints(0, 0) == 1.0);

    /* JIT URLs: both layers round-trip reserved characters and the exact script. */
    const unsigned char bytes[] = {0xfb, 0xef, 0xff, 0, 0x61};
    NSData *script = [NSData dataWithBytes:bytes length:sizeof(bytes)];
    NSArray<NSURL *> *urls = KitsuneJITURLs(@"dev.kitsune.app", 12345, script);
    assert(urls.count == 2 && [urls[0].scheme isEqualToString:@"livecontainer"]);
    NSData *decoded = [[NSData alloc] initWithBase64EncodedString:Query(urls[0], @"url") options:0];
    NSURL *inner = [NSURL URLWithString:[[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding]];
    assert([inner isEqual:urls[1]] && [inner.scheme isEqualToString:@"stikjit"]);
    assert([Query(inner, @"pid") isEqualToString:@"12345"] && [Query(inner, @"bundle-id") isEqualToString:@"dev.kitsune.app"]);
    assert([[[NSData alloc] initWithBase64EncodedString:Query(inner, @"script-data") options:0] isEqual:script]);
    assert(!Query(inner, @"script-name") && !KitsuneJITURLs(@"bundle", 1, nil).count && !KitsuneJITURLs(@"bundle", 0, script).count);
    /* A restart has StikDebug launch the app: the same URL, with no pid. */
    NSArray<NSURL *> *relaunch = KitsuneRelaunchURLs(@"dev.kitsune.app", script);
    NSURL *launchInner = [NSURL URLWithString:[[NSString alloc] initWithData:
        [[NSData alloc] initWithBase64EncodedString:Query(relaunch[0], @"url") options:0] encoding:NSUTF8StringEncoding]];
    assert(relaunch.count == 2 && [launchInner isEqual:relaunch[1]] && !Query(launchInner, @"pid") &&
           [Query(launchInner, @"bundle-id") isEqualToString:@"dev.kitsune.app"] &&
           [[[NSData alloc] initWithBase64EncodedString:Query(launchInner, @"script-data") options:0] isEqual:script]);
    assert(!KitsuneRelaunchURLs(@"", script).count && !KitsuneRelaunchURLs(@"bundle", nil).count);
    assert([fm removeItemAtPath:docs error:nil]);
    puts("STEAM LAUNCH PASS: profile from settings, play mode has no debug env, install checks, JSON round trip, JIT and relaunch URLs");
  }
}

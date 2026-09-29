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
    IOSWineLaunchOptions o = IOSWineDefaultLaunchOptions();
    NSString *error = nil;
    assert(!IOSWineSteamRequest(nil, o, docs, &error) && [error containsString:@"Steam is not installed"]);
    assert([@"stub" writeToFile:[docs stringByAppendingPathComponent:@"Apps/Steam/steam.exe"]
        atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    assert(!IOSWineSteamRequest(@"570940", o, docs, &error) && [error containsString:@"not installed"]);
    NSString *acf = @"\"AppState\"\n{\n\"appid\" \"570940\"\n\"name\" \"DARK SOULS: REMASTERED\"\n\"StateFlags\" \"1026\"\n\"installdir\" \"DARK SOULS REMASTERED\"\n}\n";
    assert([acf writeToFile:[apps stringByAppendingPathComponent:@"appmanifest_570940.acf"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    assert(!IOSWineSteamRequest(@"570940", o, docs, &error) && [error containsString:@"not fully installed"]);
    acf = [acf stringByReplacingOccurrencesOfString:@"\"1026\"" withString:@"\"4\""];
    assert([acf writeToFile:[apps stringByAppendingPathComponent:@"appmanifest_570940.acf"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);

    /* Play mode: Steam hidden whatever the setting, no debug env, tested memory policy. */
    NSDictionary *request = IOSWineSteamRequest(@"570940", o, docs, &error);
    assert(request && !error);
    assert([request[@"bottle"] isEqualToString:@"Steam"]);
    assert(o.steamVisible && ([request[@"args"] isEqual:@[@"-silent", @"-applaunch", @"570940"]]));
    NSDictionary *env = request[@"env"];
    assert([env[@"DXMT_CONFIG"] isEqualToString:@"d3d11.mipClampBC = 4; d3d11.bcMaxDim = 512"]);
    assert([env[@"IOSWINE_BC_16BIT"] isEqualToString:@"1"] && !env[@"IOSWINE_BC_NATIVE"]);
    assert([env[@"IOSWINE_ARENA_CODE_MB"] isEqualToString:@"384"] && [env[@"WINE_IOS_BIGPOOL_MB"] isEqualToString:@"1"]);
    assert([env[@"WINE_IOS_CEF_LOWBAND"] isEqualToString:@"1"] && [env[@"IOSWINE_FORCE_SWRAST"] isEqualToString:@"1"]);
    assert([env[@"IOSWINE_GAME_INPUT"] isEqualToString:@"1"] && [env[@"WINEDLLOVERRIDES"] containsString:@"xinput1_4"]);
    assert([env[@"IOSWINE_LANDSCAPE"] isEqualToString:@"1"] && !env[@"IOSWINE_SCREEN_MAX"]);
    assert([env[@"IOSWINE_STEAM_LEAN"] isEqualToString:@"1"]);
    assert(!env[@"IOSWINE_THREAD_DUMP"] && !env[@"WINEIOS_METAL_DEBUG"] && !env[@"IOSWINE_XINPUT_TRACE"] && !env[@"IOSWINE_TRACE_BIGALLOC"]);

    /* The client alone, hidden, with the console and full diagnostics. */
    o.steamVisible = NO; o.console = YES; o.diag = IOSWineDiagFull; o.frameCap = 30;
    o.textures = IOSWineTexturesNative;
    request = IOSWineSteamRequest(nil, o, docs, &error);
    assert(request && ([request[@"args"] isEqual:@[@"-console", @"-silent"]]));
    env = request[@"env"];
    assert([env[@"DXMT_CONFIG"] isEqualToString:@"d3d11.mipClampBC = 0; d3d11.preferredMaxFrameRate = 30"]);
    assert([env[@"IOSWINE_BC_NATIVE"] isEqualToString:@"1"] && !env[@"IOSWINE_BC_16BIT"]);
    assert([env[@"IOSWINE_THREAD_DUMP"] isEqualToString:@"5"] && [env[@"WINEIOS_METAL_DEBUG"] isEqualToString:@"1"]);
    assert(!env[@"IOSWINE_STEAM_LEAN"]);   /* the client alone keeps its UI */
    o.textures = IOSWineTexturesDownscaled1024; o.frameCap = 0;
    assert([IOSWineDXMTConfig(o.textures, o.frameCap) isEqualToString:@"d3d11.mipClampBC = 4; d3d11.bcMaxDim = 1024"]);

    /* The JSON written to Documents parses back into a valid request. */
    NSData *data = IOSWineSteamRequestData(@"570940", IOSWineDefaultLaunchOptions());
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    assert(IOSWineValidateLaunchRequest(json, docs, &error) && !error);

    /* Settings -> options. */
    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:@"ioswine-launch-test"];
    [ud removePersistentDomainForName:@"ioswine-launch-test"];
    IOSWineLaunchOptions s = IOSWineLaunchOptionsFromSettings(ud);
    assert(s.steamVisible && !s.console && s.diag == IOSWineDiagOff && s.textures == IOSWineTexturesDownscaled512 && s.frameCap == 0 && s.landscape);
    [ud setInteger:60 forKey:IOSWINE_KEY_FRAME_CAP];
    [ud setInteger:IOSWineTexturesNative forKey:IOSWINE_KEY_TEXTURES];
    [ud setBool:NO forKey:IOSWINE_KEY_STEAM_VISIBLE];
    IOSWineDiagStore(ud, IOSWineDiagFull);
    s = IOSWineLaunchOptionsFromSettings(ud);
    assert(!s.steamVisible && s.console && s.diag == IOSWineDiagFull && s.textures == IOSWineTexturesNative && s.frameCap == 60);
    [ud setInteger:45 forKey:IOSWINE_KEY_FRAME_CAP];
    assert(IOSWineFrameCapStored(ud) == 0);
    [ud setInteger:99 forKey:IOSWINE_KEY_TEXTURES];
    assert(IOSWineTextureModeStored(ud) == IOSWineTexturesDownscaled512);
    assert(IOSWineSafeAreaStored(ud));
    [ud removePersistentDomainForName:@"ioswine-launch-test"];

    /* Minimum scale: 800x600 must fit the safe-area desktop on both axes. */
    assert(IOSWineMinimumScaleForPoints(844, 390) == 1.6);   /* full glass, iPhone 14 */
    assert(IOSWineMinimumScaleForPoints(750, 369) == 1.7);   /* safe area, iPhone 14: 600/369 = 1.626 */
    assert(IOSWineMinimumScaleForPoints(0, 0) == 1.0);

    /* JIT URLs: both layers round-trip reserved characters and the exact script. */
    const unsigned char bytes[] = {0xfb, 0xef, 0xff, 0, 0x61};
    NSData *script = [NSData dataWithBytes:bytes length:sizeof(bytes)];
    NSArray<NSURL *> *urls = IOSWineJITURLs(@"dev.ioswine.m3boot", 12345, script);
    assert(urls.count == 2 && [urls[0].scheme isEqualToString:@"livecontainer"]);
    NSData *decoded = [[NSData alloc] initWithBase64EncodedString:Query(urls[0], @"url") options:0];
    NSURL *inner = [NSURL URLWithString:[[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding]];
    assert([inner isEqual:urls[1]] && [inner.scheme isEqualToString:@"stikjit"]);
    assert([Query(inner, @"pid") isEqualToString:@"12345"] && [Query(inner, @"bundle-id") isEqualToString:@"dev.ioswine.m3boot"]);
    assert([[[NSData alloc] initWithBase64EncodedString:Query(inner, @"script-data") options:0] isEqual:script]);
    assert(!Query(inner, @"script-name") && !IOSWineJITURLs(@"bundle", 1, nil).count && !IOSWineJITURLs(@"bundle", 0, script).count);
    /* A restart has StikDebug launch the app: the same URL, with no pid. */
    NSArray<NSURL *> *relaunch = IOSWineRelaunchURLs(@"dev.ioswine.m3boot", script);
    NSURL *launchInner = [NSURL URLWithString:[[NSString alloc] initWithData:
        [[NSData alloc] initWithBase64EncodedString:Query(relaunch[0], @"url") options:0] encoding:NSUTF8StringEncoding]];
    assert(relaunch.count == 2 && [launchInner isEqual:relaunch[1]] && !Query(launchInner, @"pid") &&
           [Query(launchInner, @"bundle-id") isEqualToString:@"dev.ioswine.m3boot"] &&
           [[[NSData alloc] initWithBase64EncodedString:Query(launchInner, @"script-data") options:0] isEqual:script]);
    assert(!IOSWineRelaunchURLs(@"", script).count && !IOSWineRelaunchURLs(@"bundle", nil).count);
    assert([fm removeItemAtPath:docs error:nil]);
    puts("STEAM LAUNCH PASS: profile from settings, play mode has no debug env, install checks, JSON round trip, JIT and relaunch URLs");
  }
}

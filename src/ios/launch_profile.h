/*
 * Launch profiles: the request the launcher hands to the boot path, built from
 *
 *   the memory and address-space policy every Steam launch needs (stack pool,
 *   big-pool band, CEF low band, FEX and arena code budgets, the swap file);
 *   the user's choices (textures, frame cap, Steam window visible or hidden,
 *   landscape);
 *   the diagnostics level, which adds its environment only at Full.
 *
 * The result goes through IOSWineValidateLaunchRequest like a launch file, so a
 * profile cannot express anything a launch file could not.
 */
#ifndef IOSWINE_LAUNCH_PROFILE_H
#define IOSWINE_LAUNCH_PROFILE_H

#import <Foundation/Foundation.h>
#include "diagnostics.h"

typedef NS_ENUM(NSInteger, IOSWineTextureMode) {
  /* BC textures decoded on the CPU into RGBA8/BGR5A1 and capped at 512 px:
   * the configuration that reached gameplay on the phone. Ugly up close. */
  IOSWineTexturesDownscaled512 = 0,
  /* Same decode, capped at 1024 px. More memory, sharper. */
  IOSWineTexturesDownscaled1024 = 1,
  /* BC transcoded to ETC2/EAC in winemetal.so so the GPU keeps them compressed
   * at their full size. New; needs a device pass before it is the default. */
  IOSWineTexturesNative = 2,
};

typedef struct {
  BOOL steamVisible;          /* NO adds -silent to the client alone: Steam starts without its window */
  BOOL console;               /* -console: Steam's console tab and its stdout log */
  IOSWineDiagLevel diag;
  IOSWineTextureMode textures;
  int frameCap;               /* 0 = the display's refresh rate */
  BOOL landscape;
} IOSWineLaunchOptions;

static inline IOSWineLaunchOptions IOSWineDefaultLaunchOptions(void) {
  IOSWineLaunchOptions o;
  memset(&o, 0, sizeof(o));
  o.steamVisible = YES;
  o.textures = IOSWineTexturesDownscaled512;
  o.landscape = YES;
  return o;
}

static inline NSString *IOSWineDXMTConfig(IOSWineTextureMode textures, int frameCap) {
  NSMutableString *cfg = [NSMutableString string];
  switch (textures) {
  case IOSWineTexturesNative:
    [cfg appendString:@"d3d11.mipClampBC = 0"];
    break;
  case IOSWineTexturesDownscaled1024:
    [cfg appendString:@"d3d11.mipClampBC = 4; d3d11.bcMaxDim = 1024"];
    break;
  default:
    [cfg appendString:@"d3d11.mipClampBC = 4; d3d11.bcMaxDim = 512"];
    break;
  }
  if (frameCap > 0) [cfg appendFormat:@"; d3d11.preferredMaxFrameRate = %d", frameCap];
  return cfg;
}

/* The request for steam.exe, launching `appID` (nil: just the client). */
static inline NSDictionary *IOSWineSteamLaunchRequest(NSString *appID, IOSWineLaunchOptions o) {
  NSMutableArray<NSString *> *args = [NSMutableArray array];
  if (o.console) [args addObject:@"-console"];
  /* A game starts Steam without its window, which spares the memory and GPU
   * time its UI takes; the setting is for opening Steam itself. */
  if (appID.length || !o.steamVisible) [args addObject:@"-silent"];
  if (appID.length) {
    [args addObject:@"-applaunch"];
    [args addObject:appID];
  }
  NSMutableDictionary<NSString *, NSString *> *env = [NSMutableDictionary dictionaryWithDictionary:@{
    /* Native iOS controller bridge, and the builtin XInput that reads it. */
    @"IOSWINE_GAME_INPUT": @"1",
    @"WINEDLLOVERRIDES": @"xinput1_1,xinput1_2,xinput1_3,xinput1_4,xinput9_1_0,xinputuap=b",
    /* Steam's memory and address-space policy, measured one lever at a time. */
    @"WINE_IOS_STACKPOOL_MB": @"512",
    @"IOSWINE_FORCE_SWRAST": @"1",
    /* Together these enable the band; BIGPOOL_MB counts by presence only. */
    @"WINE_IOS_BIGPOOL_MB": @"1",
    @"WINE_IOS_CEF_LOWBAND": @"1",
    @"IOSWINE_FEX_CODE_MB": @"48",
    @"IOSWINE_ARENA_CODE_MB": @"384",
    @"IOSWINE_SWAP": @"1",
    @"IOSWINE_SWAP_MASK": @"3",
  }];
  /* A game runs without Steam's web helper, its UI and biggest process: the
   * port ends it when the game starts and lets it back when the game exits. */
  if (appID.length) env[@"IOSWINE_STEAM_LEAN"] = @"1";
  env[@"DXMT_CONFIG"] = IOSWineDXMTConfig(o.textures, o.frameCap);
  if (o.textures == IOSWineTexturesNative) env[@"IOSWINE_BC_NATIVE"] = @"1";
  else env[@"IOSWINE_BC_16BIT"] = @"1";
  env[@"IOSWINE_LANDSCAPE"] = o.landscape ? @"1" : @"0";
  [env addEntriesFromDictionary:IOSWineDiagLaunchEnv(o.diag)];
  return @{
    @"bottle": @"Steam",
    @"exe": @"Apps/Steam/steam.exe",
    @"args": args,
    @"env": env,
  };
}

#endif

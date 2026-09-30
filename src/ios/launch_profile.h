/*
 * Launch profiles: the request the launcher hands to the boot path, built from
 *
 *   the memory and address-space policy every Steam launch needs (stack pool,
 *   big-pool band, CEF low band, FEX and arena code budgets, the swap file);
 *   the user's choices (textures, frame cap, Steam window visible or hidden,
 *   landscape);
 *   the diagnostics level, which adds its environment only at Full.
 *
 * The result goes through KitsuneValidateLaunchRequest like a launch file, so a
 * profile cannot express anything a launch file could not.
 */
#ifndef KITSUNE_LAUNCH_PROFILE_H
#define KITSUNE_LAUNCH_PROFILE_H

#import <Foundation/Foundation.h>
#include "diagnostics.h"

typedef NS_ENUM(NSInteger, KitsuneTextureMode) {
  /* BC textures decoded on the CPU into RGBA8/BGR5A1 and capped at 512 px:
   * the configuration that reached gameplay on the phone. Ugly up close. */
  KitsuneTexturesDownscaled512 = 0,
  /* Same decode, capped at 1024 px. More memory, sharper. */
  KitsuneTexturesDownscaled1024 = 1,
  /* BC transcoded to ETC2/EAC in winemetal.so so the GPU keeps them compressed
   * at their full size. New; needs a device pass before it is the default. */
  KitsuneTexturesNative = 2,
};

typedef struct {
  BOOL steamVisible;          /* NO adds -silent to the client alone: Steam starts without its window */
  BOOL console;               /* -console: Steam's console tab and its stdout log */
  KitsuneDiagLevel diag;
  KitsuneTextureMode textures;
  int frameCap;               /* 0 = the display's refresh rate */
  BOOL landscape;
} KitsuneLaunchOptions;

static inline KitsuneLaunchOptions KitsuneDefaultLaunchOptions(void) {
  KitsuneLaunchOptions o;
  memset(&o, 0, sizeof(o));
  o.steamVisible = YES;
  o.textures = KitsuneTexturesDownscaled512;
  o.landscape = YES;
  return o;
}

static inline NSString *KitsuneDXMTConfig(KitsuneTextureMode textures, int frameCap) {
  NSMutableString *cfg = [NSMutableString string];
  switch (textures) {
  case KitsuneTexturesNative:
    [cfg appendString:@"d3d11.mipClampBC = 0"];
    break;
  case KitsuneTexturesDownscaled1024:
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
static inline NSDictionary *KitsuneSteamLaunchRequest(NSString *appID, KitsuneLaunchOptions o) {
  NSMutableArray<NSString *> *args = [NSMutableArray array];
  if (o.console) [args addObject:@"-console"];   /* overrides -silent: Steam's UI shows */
  /* A game starts Steam without its window, which spares the memory and GPU
   * time its UI takes; the setting is for opening Steam itself. */
  if (appID.length || !o.steamVisible) [args addObject:@"-silent"];
  if (appID.length) {
    [args addObject:@"-applaunch"];
    [args addObject:appID];
  }
  NSMutableDictionary<NSString *, NSString *> *env = [NSMutableDictionary dictionaryWithDictionary:@{
    /* Native iOS controller bridge, and the builtin XInput that reads it. */
    @"KITSUNE_GAME_INPUT": @"1",
    @"WINEDLLOVERRIDES": @"xinput1_1,xinput1_2,xinput1_3,xinput1_4,xinput9_1_0,xinputuap=b",
    /* Steam's memory and address-space policy, measured one lever at a time. */
    @"WINE_IOS_STACKPOOL_MB": @"512",
    @"KITSUNE_FORCE_SWRAST": @"1",
    /* Together these enable the band; BIGPOOL_MB counts by presence only. */
    @"WINE_IOS_BIGPOOL_MB": @"1",
    @"WINE_IOS_CEF_LOWBAND": @"1",
    @"KITSUNE_FEX_CODE_MB": @"48",
    @"KITSUNE_ARENA_CODE_MB": @"384",
    @"KITSUNE_SWAP": @"1",
    @"KITSUNE_SWAP_MASK": @"3",
  }];
  /* No KITSUNE_STEAM_LEAN: -silent already keeps Steam's UI hidden, and ending
   * its web helper while refusing the restarts Steam keeps asking for left
   * games running worse than beside a hidden helper. A launch request can still set it. */
  /* Large sampled RGBA8 textures stored as ETC2 (winemetal): Unity games ship
   * uncompressed atlases (Blasphemous: 2.2 GB of them, past the 4 GB limit). */
  env[@"KITSUNE_RGBA_ETC2"] = @"1";
  env[@"DXMT_CONFIG"] = KitsuneDXMTConfig(o.textures, o.frameCap);
  if (o.textures == KitsuneTexturesNative) env[@"KITSUNE_BC_NATIVE"] = @"1";
  else env[@"KITSUNE_BC_16BIT"] = @"1";
  env[@"KITSUNE_LANDSCAPE"] = o.landscape ? @"1" : @"0";
  [env addEntriesFromDictionary:KitsuneDiagLaunchEnv(o.diag)];
  return @{
    @"bottle": @"Steam",
    @"exe": @"Apps/Steam/steam.exe",
    @"args": args,
    @"env": env,
  };
}

#endif

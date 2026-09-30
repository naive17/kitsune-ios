/*
 * The launcher's persisted choices, and how they become launch options.
 *
 * NSUserDefaults rather than a launch json, and for a measured reason: the
 * screen snapshot in wine_surface.m runs when the view is created, BEFORE any
 * launch request's env is applied, so a setting that shapes the desktop must
 * be readable that early. Everything else lives here too so there is one place
 * to look.
 */
#ifndef KITSUNE_LAUNCHER_SETTINGS_H
#define KITSUNE_LAUNCHER_SETTINGS_H

#import <Foundation/Foundation.h>
#include <math.h>
#include "launch_profile.h"

#define KITSUNE_KEY_OTHER_LANDSCAPE @"KitsuneOtherProgramsLandscape" /* orientation for programs that aren't games */
#define KITSUNE_KEY_RENDER_SCALE   @"KitsuneRenderScale"
#define KITSUNE_KEY_SAFE_AREA      @"KitsuneSafeArea"        /* keep the desktop off the notch */
#define KITSUNE_KEY_FRAME_CAP      @"KitsuneFrameCap"        /* 0, 30, 40, 60 */
#define KITSUNE_KEY_TEXTURES       @"KitsuneTextureMode"     /* KitsuneTextureMode */
#define KITSUNE_KEY_STEAM_VISIBLE  @"KitsuneSteamVisible"
#define KITSUNE_KEY_LOW_POWER_AUTO @"KitsuneLowPowerAuto"    /* Battery mode while Low Power Mode is on */
#define KITSUNE_KEY_FILL_SCREEN    @"KitsuneFillScreen"      /* set known games to the desktop resolution */
#define KITSUNE_KEY_PERF_HUD       @"KitsunePerfHUD"         /* fps and memory readout in session */
#define KITSUNE_KEY_POINTER_MODE   @"KitsunePointerMode"     /* WinePointerMode last used */
#define KITSUNE_KEY_LOOK_SENS      @"KitsuneLookSensitivity" /* look-mode gain */
#define KITSUNE_KEY_METAL_HUD      @"KitsuneMetalHUD"        /* Apple's Metal performance HUD, next launch */
#define KITSUNE_KEY_TOUCH_PAD      @"KitsuneTouchPad"        /* on-screen controller for Steam games */

/* Landscape scale for games; 0 when none was chosen. 1.6 is the smallest that
 * keeps 800x600 inside a 844x390 pt screen (1350x624); the safe-area desktop is
 * smaller and needs more, see KitsuneMinimumScaleForPoints. */
static inline double KitsuneRenderScaleStored(NSUserDefaults *ud) {
  double v = [ud doubleForKey:KITSUNE_KEY_RENDER_SCALE];
  return v >= 1.0 ? v : 0.0;
}

static inline BOOL KitsuneSafeAreaStored(NSUserDefaults *ud) {
  return [ud objectForKey:KITSUNE_KEY_SAFE_AREA] ? [ud boolForKey:KITSUNE_KEY_SAFE_AREA] : YES;
}

static inline BOOL KitsuneFillScreenStored(NSUserDefaults *ud) {
  return [ud objectForKey:KITSUNE_KEY_FILL_SCREEN] ? [ud boolForKey:KITSUNE_KEY_FILL_SCREEN] : YES;
}

static inline BOOL KitsunePerfHUDStored(NSUserDefaults *ud) {
  return [ud objectForKey:KITSUNE_KEY_PERF_HUD] ? [ud boolForKey:KITSUNE_KEY_PERF_HUD] : YES;
}

static inline double KitsuneLookSensitivityStored(NSUserDefaults *ud) {
  double v = [ud doubleForKey:KITSUNE_KEY_LOOK_SENS];
  return v > 0 ? v : 1.0;
}

/* A WinePointerMode (input_overlay.h: 0 touch, 1 trackpad, 2 look). Trackpad
 * until one is chosen: it is the mode that can reach every pixel. */
static inline NSInteger KitsunePointerModeStored(NSUserDefaults *ud) {
  NSInteger v = [ud integerForKey:KITSUNE_KEY_POINTER_MODE];
  return [ud objectForKey:KITSUNE_KEY_POINTER_MODE] && v >= 0 && v <= 2 ? v : 1;
}
static inline BOOL KitsuneTouchPadStored(NSUserDefaults *ud) {
  return [ud objectForKey:KITSUNE_KEY_TOUCH_PAD] ? [ud boolForKey:KITSUNE_KEY_TOUCH_PAD] : YES;
}

static inline BOOL KitsuneSteamVisibleStored(NSUserDefaults *ud) {
  return [ud objectForKey:KITSUNE_KEY_STEAM_VISIBLE] ? [ud boolForKey:KITSUNE_KEY_STEAM_VISIBLE] : YES;
}

static inline BOOL KitsuneLowPowerAutoStored(NSUserDefaults *ud) {
  return [ud objectForKey:KITSUNE_KEY_LOW_POWER_AUTO] ? [ud boolForKey:KITSUNE_KEY_LOW_POWER_AUTO] : YES;
}

static inline int KitsuneFrameCapStored(NSUserDefaults *ud) {
  NSInteger v = [ud integerForKey:KITSUNE_KEY_FRAME_CAP];
  return (v == 30 || v == 40 || v == 60) ? (int)v : 0;
}

static inline KitsuneTextureMode KitsuneTextureModeStored(NSUserDefaults *ud) {
  NSInteger v = [ud integerForKey:KITSUNE_KEY_TEXTURES];
  if (v < KitsuneTexturesDownscaled512 || v > KitsuneTexturesNative) return KitsuneTexturesDownscaled512;
  return (KitsuneTextureMode)v;
}

/* The smallest landscape scale at which an 800x600 mode still fits a desktop
 * cut from `points` (the safe-area rect in points). Games such as Dark Souls
 * Remastered keep only modes that fit SM_CXSCREEN x SM_CYSCREEN and are at
 * least 800x600, so both sides must clear it; rounded up to 0.1. */
static inline double KitsuneMinimumScaleForPoints(double width, double height) {
  if (width <= 0 || height <= 0) return 1.0;
  double s = 800.0 / width;
  if (600.0 / height > s) s = 600.0 / height;
  s = ceil(s * 10.0 - 1e-9) / 10.0;
  return s < 1.0 ? 1.0 : s;
}

/* The options a Steam launch uses. Low Power Mode is not among them: the
 * power modes apply it live (power.h). */
static inline KitsuneLaunchOptions KitsuneLaunchOptionsFromSettings(NSUserDefaults *ud) {
  KitsuneLaunchOptions o = KitsuneDefaultLaunchOptions();
  o.diag = KitsuneDiagLevelStored(ud);
  o.console = (o.diag == KitsuneDiagFull);
  o.steamVisible = KitsuneSteamVisibleStored(ud);
  o.textures = KitsuneTextureModeStored(ud);
  o.frameCap = KitsuneFrameCapStored(ud);
  o.landscape = YES;   /* games need the long side wide; the client copes */
  return o;
}

#endif

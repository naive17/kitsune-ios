#import "power.h"
#import "diagnostics.h"
#import "launcher_settings.h"

#import <UIKit/UIKit.h>

NSNotificationName const WinePowerDidChangeNotification = @"WinePowerDidChange";

/* Read by ntdll's wait paths: (generation << 8) | class, where class is
 * 0 default, 1 user-interactive, 2 user-initiated, 3 utility. Zero means
 * never set, so threads leave their QoS alone. */
__attribute__((visibility("default"))) volatile unsigned kitsune_guest_qos_state;
/* Read by winemetal at each present; seconds, 0 for no minimum. */
__attribute__((visibility("default"))) volatile double kitsune_present_min_interval;

#define KITSUNE_KEY_POWER_MODE @"KitsunePowerMode"

@implementation WinePower {
  unsigned _generation;
  BOOL _started;
  NSInteger _thermal;   /* last thermal state logged, -1 before the first */
}

+ (instancetype)shared {
  static WinePower *p;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ p = [WinePower new]; });
  return p;
}

- (WinePowerMode)userMode {
  NSInteger v = [NSUserDefaults.standardUserDefaults integerForKey:KITSUNE_KEY_POWER_MODE];
  return (v >= WinePowerBalanced && v <= WinePowerBattery) ? (WinePowerMode)v : WinePowerBalanced;
}

- (void)setUserMode:(WinePowerMode)mode {
  [NSUserDefaults.standardUserDefaults setInteger:mode forKey:KITSUNE_KEY_POWER_MODE];
  [self update];
}

- (void)start {
  if (_started) return;
  _started = YES;
  NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
  [nc addObserver:self selector:@selector(update) name:NSProcessInfoPowerStateDidChangeNotification object:nil];
  [nc addObserver:self selector:@selector(update) name:NSProcessInfoThermalStateDidChangeNotification object:nil];
  [self update];
}

- (void)update {
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self update]; });
    return;
  }
  NSProcessInfo *pi = NSProcessInfo.processInfo;
  NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
  WinePowerMode mode = self.userMode;
  NSString *reason = NSLocalizedString(@"chosen in Settings", nil);
  if (pi.thermalState >= NSProcessInfoThermalStateSerious && KitsuneHotAutoStored(ud)) {
    mode = WinePowerBattery;
    reason = NSLocalizedString(@"the phone is hot", nil);
  } else if (pi.lowPowerModeEnabled && KitsuneLowPowerAutoStored(ud)) {
    mode = WinePowerBattery;
    reason = NSLocalizedString(@"Low Power Mode is on", nil);
  }
  /* iOS lowers clocks from Serious on whatever the mode, so the log records
   * every thermal change: a slow run is otherwise indistinguishable from a
   * slow build. */
  if (!_generation) _thermal = -1;
  if (pi.thermalState != _thermal) {
    _thermal = pi.thermalState;
    KitsuneLog([NSString stringWithFormat:@"THERMAL %ld", (long)_thermal]);
  }
  BOOL changed = (mode != _effectiveMode) || !_generation;
  _effectiveMode = mode;
  _batteryReason = mode == WinePowerBattery ? [reason copy] : nil;

  int cap = mode == WinePowerBattery ? 30 : 0;
  kitsune_present_min_interval = cap > 0 ? 1.0 / cap : 0.0;

  if (changed) {
    unsigned cls = mode == WinePowerPerformance ? 1 : mode == WinePowerBattery ? 3 : 0;
    /* Balanced at start leaves threads untouched; any later change is explicit. */
    if (_generation || mode != WinePowerBalanced) {
      _generation++;
      __atomic_store_n(&kitsune_guest_qos_state, (_generation << 8) | cls, __ATOMIC_RELEASE);
    } else {
      _generation = 1;
    }
    KitsuneLog([NSString stringWithFormat:@"POWER mode=%ld (%@) cap=%d thermal=%ld lowpower=%d",
                (long)mode, reason, cap, (long)pi.thermalState, pi.lowPowerModeEnabled]);
  }
  [NSNotificationCenter.defaultCenter postNotificationName:WinePowerDidChangeNotification object:self];
}

@end

#import <UIKit/UIKit.h>

#include "boot_vc.h"
#include "diagnostics.h"
#include "jit_arena.h"
#include "power.h"
#include "wine_surface.h"

#include <dlfcn.h>
#include <os/proc.h>

#define WINE_SHARED_DATA_ADDR 0x120000000ull
#ifndef ARENA_MB
#define ARENA_MB 1024
#endif
#ifndef ARENA_MAX_MB
#define ARENA_MAX_MB 1024
#endif

/* MTLSetShaderCachePath is honoured only before Metal is initialised, so it
 * must run at the top of main, not from dxgi.dll's DllMain. */
static void PlaceMetalFrameworkCache(void) {
  NSString *dir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject
                   stringByAppendingPathComponent:@"metal-framework"];
  [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
  void (*set)(CFStringRef) = dlsym(RTLD_DEFAULT, "MTLSetShaderCachePath");
  if (set) set((__bridge CFStringRef)dir);
}

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)o {
  (void)o;
  /* A locked screen suspends the app and the watchdog kills the pinned JIT
   * thread; the session keeps the screen awake. */
  app.idleTimerDisabled = YES;
  [WinePower.shared start];
  return YES;
}
@end

@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, assign) UIBackgroundTaskIdentifier bgTask;
@end

@implementation SceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
  (void)s; (void)o;
  if (![scene isKindOfClass:UIWindowScene.class]) return;
  self.bgTask = UIBackgroundTaskInvalid;
  self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
  self.window.rootViewController = [WineBootVC new];
  [self.window makeKeyAndVisible];
  /* The driver reaches the host through dlsym and snapshots the screen here,
   * on the main thread, before any Wine thread exists. */
  wine_surface_host_init((__bridge void *)self.window.rootViewController.view);
}

/* The JIT hand-off bounces through LiveContainer and StikDebug; a background
 * task keeps the boot alive for that window. */
- (void)sceneDidEnterBackground:(UIScene *)scene {
  (void)scene;
  if (self.bgTask != UIBackgroundTaskInvalid) return;
  __weak SceneDelegate *weakSelf = self;
  self.bgTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"kitsune-boot" expirationHandler:^{
    SceneDelegate *s = weakSelf;
    if (s && s.bgTask != UIBackgroundTaskInvalid) {
      [UIApplication.sharedApplication endBackgroundTask:s.bgTask];
      s.bgTask = UIBackgroundTaskInvalid;
    }
  }];
}

- (void)sceneWillEnterForeground:(UIScene *)scene {
  (void)scene;
  if (self.bgTask == UIBackgroundTaskInvalid) return;
  [UIApplication.sharedApplication endBackgroundTask:self.bgTask];
  self.bgTask = UIBackgroundTaskInvalid;
}
@end

/* Hold the low arena window before UIKit and Metal map anything, so the
 * debugger's first-fit placement lands at the same address every launch. */
__attribute__((constructor)) static void PinArenaWindow(void) {
  ios_jit_arena_pin_low_adaptive((void *)(WINE_SHARED_DATA_ADDR + 0x10000), (size_t)ARENA_MB << 20, (size_t)ARENA_MAX_MB << 20);
}

int main(int argc, char *argv[]) {
  ios_jit_arena_pin_low_adaptive((void *)(WINE_SHARED_DATA_ADDR + 0x10000), (size_t)ARENA_MB << 20, (size_t)ARENA_MAX_MB << 20);
  [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                                                  object:nil queue:nil usingBlock:^(NSNotification *n __unused) {
    KitsuneLog([NSString stringWithFormat:@"MEMORY-WARNING avail=%lluMB footprint=%lluMB",
                   (unsigned long long)(os_proc_available_memory() >> 20), KitsunePhysFootprintMB()]);
    static void (*rss)(const char *);
    if (!rss) rss = dlsym(RTLD_DEFAULT, "ios_rss_report");
    if (rss) rss("MEMORY-WARNING");
  }];
  @autoreleasepool {
    /* Read by Metal when it initialises, so it has to be set first. */
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"KitsuneMetalHUD"]) setenv("MTL_HUD_ENABLED", "1", 1);
    PlaceMetalFrameworkCache();
    KitsuneDiagApplyToEnvironment(NSUserDefaults.standardUserDefaults);
    return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class));
  }
}

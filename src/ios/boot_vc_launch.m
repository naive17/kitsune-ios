#import "boot_vc_private.h"

#include "app_library.h"
#include "bottles.h"
#include "diagnostics.h"
#include "game_config.h"
#include "jit_arena.h"
#include "launcher_settings.h"
#include "session.h"
#include "steam_launch.h"
#include "wine_surface.h"

#include <dlfcn.h>

/* A launcher argv without its leading "wine". */
static NSArray<NSString *> *ProgramArgv(NSArray<NSString *> *argv) {
  return argv.count > 1 ? [argv subarrayWithRange:NSMakeRange(1, argv.count - 1)] : @[];
}

@implementation WineBootVC (Launch)

/* --- launcher ------------------------------------------------------------ */

/* Shown while the runtime prepares, unless a queued request will boot
 * straight into a program. */
- (void)presentLauncherEarly {
  NSFileManager *fm = NSFileManager.defaultManager;
  if (([fm fileExistsAtPath:RequestPath()] || [fm fileExistsAtPath:PendingLaunchPath()]) && CSDebugged(NULL)) return;
  [self showLauncher];
}

- (void)showLauncher {
  [self showLauncherAsSheet:NO];
}

/* Full screen, or as a sheet over a running program that a swipe returns to. */
- (void)showLauncherAsSheet:(BOOL)sheet {
  if (!_launcher) {
    _launcher = [WineLauncherVC new];
    _launcher.launcherDelegate = self;
  }
  if (_launcher.presentingViewController) return;
  _launcher.modalPresentationStyle = sheet ? UIModalPresentationPageSheet : UIModalPresentationFullScreen;
  [self presentViewController:_launcher animated:YES completion:nil];
}

- (void)presentLauncher {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    [WineAppLibrary.shared rescanBuiltinsInTree:WineTreeRoot()];
    [WineAppLibrary.shared rescanInstalledInPrefix:WineBootPrefix()];
    dispatch_async(dispatch_get_main_queue(), ^{
      [self setPhase:WineBootPhaseReady message:NSLocalizedString(@"Ready", nil)];
      [self showLauncher];
      [self->_launcher refreshAll];
    });
  });
}

- (void)launcherShowBootDetails:(WineLauncherVC *)vc {
  [vc dismissViewControllerAnimated:YES completion:nil];
  _out.hidden = NO;
  [_details setTitle:NSLocalizedString(@"Hide Details", nil) forState:UIControlStateNormal];
  _shownLen = 0;
  _out.text = @"";
  [self scheduleLogFlush];
  _libraryBtn.hidden = NO;
}

- (void)onShowLibrary {
  [self showLauncher];
}

- (void)openJITURLs:(NSArray<NSURL *> *)urls atIndex:(NSUInteger)index {
  if (index >= urls.count) {
    [self cancelQueuedLaunch];
    [self setPhase:WineBootPhaseNeedsJIT message:NSLocalizedString(@"Couldn't open StikDebug.", nil)];
    [_launcher report:NSLocalizedString(@"StikDebug Unavailable", nil) message:NSLocalizedString(@"Check StikDebug's pairing file and VPN, then try again.", nil)];
    return;
  }
  [UIApplication.sharedApplication openURL:urls[index] options:@{} completionHandler:^(BOOL ok) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!ok) [self openJITURLs:urls atIndex:index + 1];
    });
  }];
}

- (void)launcher:(WineLauncherVC *)vc playSteamApp:(NSString *)appID named:(NSString *)name {
  if (_quickLaunchPending) return;
  /* A game always gets a Steam of its own, started -silent so its UI never
   * shows. Handed to a running Steam, its -silent -applaunch only raises
   * Steam's window. Steam alone still runs in the session, which is how its
   * window is brought up. */
  if (_wineStopped || _jitFailed || (_sessionBottle && (![_sessionBottle isEqualToString:@"Steam"] || appID.length))) {
    [self restartIntoSteamApp:appID named:name from:vc];
    return;
  }
  if (_sessionBottle) {
    NSString *reason = nil;
    NSDictionary *request = KitsuneSteamRequest(appID, KitsuneLaunchOptionsFromSettings(NSUserDefaults.standardUserDefaults),
                                                KitsunePersistentDocuments(), &reason);
    if (!request) {
      [vc report:NSLocalizedString(@"Can't Launch", nil) message:reason ?: NSLocalizedString(@"The launch request is invalid.", nil)];
      return;
    }
    [self fitSteamGameToScreen:appID];
    NSString *exe = request[@"exe"];
    NSArray<NSString *> *args = request[@"args"];
    if (!appID.length) {
      /* Steam runs here already, hidden if a game started it: ask it for its
       * window, and let lean mode start the web helper (its UI) for that even
       * while the game runs. */
      static void (*want_ui)(void);
      if (!want_ui) want_ui = (void (*)(void))dlsym(RTLD_DEFAULT, "ios_lean_want_steam_ui");
      if (want_ui) want_ui();
      args = [args arrayByAddingObject:@"steam://open/main"];
    }
    if ([self runInSession:[@[ @"wine", exe ] arrayByAddingObjectsFromArray:args]
                workingDir:exe.stringByDeletingLastPathComponent bottle:request[@"bottle"] label:name ?: NSLocalizedString(@"Steam", nil) from:vc] &&
        appID.length && _input) {
      _padWanted = KitsuneTouchPadStored(NSUserDefaults.standardUserDefaults);
      [self applyPad];
    }
    return;
  }
  BOOL jitReady = ios_jit_arena_available();
  if (jitReady && WineBootStatus.shared.phase != WineBootPhaseReady) {
    [vc report:NSLocalizedString(@"Not ready", nil) message:WineBootStatus.shared.message];
    return;
  }
  size_t arena = jitReady ? ios_jit_arena_size() : ios_jit_arena_pinned_len();
  if (arena < (size_t)1024 * 1024 * 1024) {
    /* A new process places a new arena. */
    [self restartIntoSteamApp:appID named:name from:vc];
    return;
  }
  NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
  KitsuneLaunchOptions options = KitsuneLaunchOptionsFromSettings(ud);
  NSString *reason = nil;
  if (!KitsuneSteamRequest(appID, options, KitsunePersistentDocuments(), &reason)) {
    [vc report:NSLocalizedString(@"Can't Launch", nil) message:reason ?: NSLocalizedString(@"The launch request is invalid.", nil)];
    return;
  }
  NSData *script = [NSData dataWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"kitsune" ofType:@"js"]];
  NSArray<NSURL *> *urls = KitsuneJITURLs(NSBundle.mainBundle.bundleIdentifier, getpid(), script);
  if (!jitReady && !urls.count) {
    [vc report:NSLocalizedString(@"JIT Script Missing", nil) message:NSLocalizedString(@"Reinstall Kitsune.", nil)];
    return;
  }
  NSError *error = nil;
  if (![KitsuneSteamRequestData(appID, options) writeToFile:RequestPath() options:NSDataWritingAtomic error:&error]) {
    [vc report:NSLocalizedString(@"Can't Launch", nil) message:error.localizedDescription];
    return;
  }
  [NSFileManager.defaultManager removeItemAtPath:
      [KitsunePersistentDocuments() stringByAppendingPathComponent:@"dxmt-gpu-debug.txt"] error:nil];
  [self fitSteamGameToScreen:appID];
  _quickLaunchPending = YES;
  if (jitReady) [self setPhase:WineBootPhaseLaunching message:[NSString stringWithFormat:NSLocalizedString(@"Starting %@", nil), name ?: NSLocalizedString(@"Steam", nil)]];
  else [self setPhase:WineBootPhaseWaitingJIT message:NSLocalizedString(@"Enabling JIT…", nil)];
  KitsuneLog([NSString stringWithFormat:@"PLAY app=%@ textures=%ld cap=%d diag=%ld",
                 appID ?: @"client", (long)options.textures, options.frameCap, (long)options.diag]);
  if (jitReady) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [self finishRuntimeSetup]; });
  } else {
    dispatch_semaphore_signal(_jitRequestGate);
    [self openJITURLs:urls atIndex:0];
  }
}

/* Steam in a new process: the request waits in launch-request.json, which
 * carries Steam's memory policy for the boot. */
- (void)restartIntoSteamApp:(NSString *)appID named:(NSString *)name from:(WineLauncherVC *)vc {
  KitsuneLaunchOptions options = KitsuneLaunchOptionsFromSettings(NSUserDefaults.standardUserDefaults);
  NSString *reason = nil;
  if (!KitsuneSteamRequest(appID, options, KitsunePersistentDocuments(), &reason)) {
    [vc report:NSLocalizedString(@"Can't Launch", nil) message:reason ?: NSLocalizedString(@"The launch request is invalid.", nil)];
    return;
  }
  [self restartToOpen:name ?: NSLocalizedString(@"Steam", nil) bottle:@"Steam" from:vc saving:^NSString *{
    NSError *error = nil;
    if (![KitsuneSteamRequestData(appID, options) writeToFile:RequestPath() options:NSDataWritingAtomic error:&error])
      return error.localizedDescription;
    [NSFileManager.defaultManager removeItemAtPath:
        [KitsunePersistentDocuments() stringByAppendingPathComponent:@"dxmt-gpu-debug.txt"] error:nil];
    [self fitSteamGameToScreen:appID];
    return nil;
  }];
}

/* With Fill Screen on, the game's own config asks for the desktop's size. */
- (void)fitSteamGameToScreen:(NSString *)appID {
  int w = 0, h = 0;
  if (!appID.length || !KitsuneFillScreenStored(NSUserDefaults.standardUserDefaults) ||
      !wine_surface_expected_landscape_desktop(&w, &h))
    return;
  NSString *changed = KitsuneApplyGameResolution(appID, [KitsunePersistentDocuments()
      stringByAppendingPathComponent:@"Bottles/Steam"], w, h);
  KitsuneLog([NSString stringWithFormat:@"PLAY desktop %dx%d config=%@", w, h, changed.lastPathComponent ?: @"unchanged"]);
}

- (void)launcherEnableJIT:(WineLauncherVC *)vc {
  [self requestJITFrom:vc];
}

/* Open StikDebug for this process. The boot thread, parked on the gate,
 * polls for the grant and then prepares the runtime. */
- (BOOL)requestJITFrom:(WineLauncherVC *)vc {
  if (_quickLaunchPending || ios_jit_arena_available()) return NO;
  if (_jitFailed) {
    [self relaunch];
    return NO;
  }
  NSData *script = [NSData dataWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"kitsune" ofType:@"js"]];
  NSArray<NSURL *> *urls = KitsuneJITURLs(NSBundle.mainBundle.bundleIdentifier, getpid(), script);
  if (!urls.count) {
    [vc report:NSLocalizedString(@"JIT Script Missing", nil) message:NSLocalizedString(@"Reinstall Kitsune.", nil)];
    return NO;
  }
  _quickLaunchPending = YES;
  [self setPhase:WineBootPhaseWaitingJIT message:NSLocalizedString(@"Enabling JIT…", nil)];
  dispatch_semaphore_signal(_jitRequestGate);
  [self openJITURLs:urls atIndex:0];
  return YES;
}

- (void)launcher:(WineLauncherVC *)vc runArgv:(NSArray<NSString *> *)argv
      workingDir:(NSString *)cwd bottle:(NSString *)bottle gui:(BOOL)gui label:(NSString *)label {
  NSString *target = bottle.length ? bottle : KITSUNE_DEFAULT_BOTTLE;
  if (_wineStopped || _jitFailed || (_sessionBottle && ![target isEqualToString:_sessionBottle])) {
    NSDictionary *pending = @{ @"argv": argv, @"cwd": cwd ?: @"", @"bottle": target, @"gui": @(gui),
                               @"label": label ?: NSLocalizedString(@"program", nil) };
    [self restartToOpen:pending[@"label"] bottle:target from:vc saving:^NSString *{
      return [pending writeToFile:PendingLaunchPath() atomically:YES]
          ? nil : NSLocalizedString(@"Couldn't save the program to open after the restart.", nil);
    }];
    return;
  }
  if (_sessionBottle) {
    [self runInSession:argv workingDir:cwd bottle:bottle.length ? bottle : KITSUNE_DEFAULT_BOTTLE label:label from:vc];
    return;
  }
  if (vc && !ios_jit_arena_available()) {
    /* Chosen before JIT: remember it, get JIT, run it once the runtime is up. */
    if (bottle.length && ![bottle isEqualToString:KITSUNE_DEFAULT_BOTTLE]) WineBootSelectBottle(bottle);
    NSDictionary *pending = @{ @"argv": argv, @"cwd": cwd ?: @"", @"bottle": bottle ?: @"", @"gui": @(gui), @"label": label ?: NSLocalizedString(@"program", nil) };
    if ([self requestJITFrom:vc]) _pendingLaunch = pending;
    return;
  }
  if (vc && WineBootStatus.shared.phase != WineBootPhaseReady) {
    [vc report:NSLocalizedString(@"Not ready", nil) message:WineBootStatus.shared.message];
    return;
  }
  if (bottle.length && ![bottle isEqualToString:KITSUNE_DEFAULT_BOTTLE]) WineBootSelectBottle(bottle);
  if (gui) {
    /* Wine's root process is the session host; the program waits in its queue
     * and later ones from the same bottle join it there. */
    if (!KitsuneSessionQueue(ProgramArgv(argv), cwd)) {
      [self reportLaunchFailure:NSLocalizedString(@"The command line is too long.", nil) from:vc];
      return;
    }
    _argv = @[ @"wine", KitsuneSessionHostPath() ];
    _sessionBottle = bottle.length ? bottle : KITSUNE_DEFAULT_BOTTLE;
    setenv("KITSUNE_PROCESS_CACHE_EXPERIMENT", "1", 1);
    setenv("KITSUNE_THREADED_PROCESS", "1", 1);
  } else {
    /* Console programs run alone, as Wine's root process. Portable programs
     * resolve their files relative to their own directory. */
    _argv = argv;
    if (cwd.length && chdir(cwd.fileSystemRepresentation) != 0)
      [self say:[NSString stringWithFormat:@"warning: could not enter %@", cwd]];
  }
  /* Games get landscape from their launch request; other programs follow the
   * setting. The app itself stays in whatever orientation the phone is in. */
  const char *landscape = getenv("KITSUNE_LANDSCAPE");
  _landscape = landscape && *landscape ? atoi(landscape) != 0
                                       : gui && [NSUserDefaults.standardUserDefaults boolForKey:KITSUNE_KEY_OTHER_LANDSCAPE];
  wine_surface_host_set_landscape(_landscape);
  _sessionLandscape = _landscape;
  [self forceLandscapeIfAsked];
  KitsuneLog([NSString stringWithFormat:@"LAUNCH %@ gui=%d landscape=%d", label, gui, _landscape]);
  [self setPhase:WineBootPhaseLaunching message:[NSString stringWithFormat:NSLocalizedString(@"Starting %@", nil), label]];
  [self dismissViewControllerAnimated:NO completion:^{
    if (gui) {
      [self showInputLayer];
      [self startSessionTimer];
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [self launchWine]; });
  }];
}

/* --- restart --------------------------------------------------------------- */

/* Wine starts once per process, for one bottle, and cannot be torn down and
 * started again in it. Another bottle, or anything after Wine has stopped,
 * takes a new process: `save` records what to open (pending-launch.plist, or
 * launch-request.json for Steam), this process exits, which ends its programs
 * and frees all they held, and StikDebug launches a new instance under JIT
 * that opens it. Running programs make it ask first. */
- (void)restartToOpen:(NSString *)label bottle:(NSString *)bottle from:(WineLauncherVC *)vc
               saving:(NSString *(^)(void))save {
  void (^restart)(void) = ^{
    NSString *failure = save();
    if (failure) { [self reportLaunchFailure:failure from:vc]; return; }
    [self relaunch];
  };
  if (_wineStopped || _jitFailed || KitsuneSessionPrograms() <= 0) { restart(); return; }
  UIAlertController *ask = [UIAlertController
      alertControllerWithTitle:[NSString stringWithFormat:NSLocalizedString(@"Open %@?", nil), label]
                       message:[NSString stringWithFormat:NSLocalizedString(@"Kitsune restarts to open the %@ bottle. Programs running in the %@ bottle will close.", nil),
                                                          bottle, _sessionBottle]
                preferredStyle:UIAlertControllerStyleAlert];
  [ask addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
  [ask addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Restart", nil) style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *action __unused) { restart(); }]];
  UIViewController *host = vc ?: self;
  while (host.presentedViewController) host = host.presentedViewController;
  [host presentViewController:ask animated:YES completion:nil];
}

- (void)relaunch {
  NSData *script = [NSData dataWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"kitsune" ofType:@"js"]];
  KitsuneLog(@"RESTART");
  [self setPhase:WineBootPhaseLaunching message:NSLocalizedString(@"Restarting…", nil)];
  [self openRelaunchURLs:KitsuneRelaunchURLs(NSBundle.mainBundle.bundleIdentifier, script) atIndex:0];
}

- (void)openRelaunchURLs:(NSArray<NSURL *> *)urls atIndex:(NSUInteger)index {
  if (index >= urls.count) {
    /* What to open stays saved: the next start of Kitsune opens it. */
    [self setPhase:WineBootPhaseFailed message:NSLocalizedString(@"Couldn't open StikDebug. Close Kitsune and open it again to continue.", nil)];
    return;
  }
  [UIApplication.sharedApplication openURL:urls[index] options:@{} completionHandler:^(BOOL ok) {
    if (!ok) {
      dispatch_async(dispatch_get_main_queue(), ^{ [self openRelaunchURLs:urls atIndex:index + 1]; });
      return;
    }
    /* StikDebug launches the new instance once this one is gone. _exit, not
     * exit: Wine's threads are still running, and its exit handlers are not
     * safe while they do. */
    _exit(0);
  }];
}

/* --- session --------------------------------------------------------------- */

- (void)reportLaunchFailure:(NSString *)message from:(WineLauncherVC *)vc {
  if (vc) [vc report:NSLocalizedString(@"Can't Launch", nil) message:message];
  else [self setPhase:WineBootPhaseFailed message:message];
}

/* A program for the running session; NO when it was refused. Another bottle
 * restarts Kitsune into that bottle (restartToOpen:). */
- (BOOL)runInSession:(NSArray<NSString *> *)argv workingDir:(NSString *)cwd bottle:(NSString *)bottle
               label:(NSString *)label from:(WineLauncherVC *)vc {
  if (![bottle isEqualToString:_sessionBottle]) {
    [self launcher:vc runArgv:argv workingDir:cwd bottle:bottle gui:YES label:label];
    return NO;
  }
  if (!KitsuneSessionQueue(ProgramArgv(argv), cwd)) {
    [self reportLaunchFailure:NSLocalizedString(@"The command line is too long.", nil) from:vc];
    return NO;
  }
  KitsuneLog([NSString stringWithFormat:@"SESSION-LAUNCH %@", label]);
  _sessionLaunchAt = CFAbsoluteTimeGetCurrent();
  _landscape = _sessionLandscape;
  [self forceLandscapeIfAsked];
  [self setPhase:WineBootPhaseLaunching message:[NSString stringWithFormat:NSLocalizedString(@"Starting %@", nil), label]];
  [self dismissViewControllerAnimated:YES completion:^{ [self showInputLayer]; }];
  return YES;
}

- (void)startSessionTimer {
  _sessionLaunchAt = CFAbsoluteTimeGetCurrent();
  [_sessionTimer invalidate];
  __weak WineBootVC *weakSelf = self;
  _sessionTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer __unused) {
    [weakSelf sessionTick];
  }];
}

/* The Library comes back once no program runs: after one has, or when the
 * last launch has started nothing for a while. */
- (void)sessionTick {
  if (KitsuneSessionPrograms() > 0) {
    _sessionBusy = YES;
    if (WineBootStatus.shared.phase != WineBootPhaseRunning) [self setPhase:WineBootPhaseRunning message:NSLocalizedString(@"Running", nil)];
    return;
  }
  if ((!_sessionBusy && CFAbsoluteTimeGetCurrent() - _sessionLaunchAt < 20) || _launcher.presentingViewController) return;
  _sessionBusy = NO;
  KitsuneLog(@"SESSION-IDLE");
  _landscape = NO;
  if (@available(iOS 16.0, *)) [self setNeedsUpdateOfSupportedInterfaceOrientations];
  [self setPhase:WineBootPhaseReady message:NSLocalizedString(@"Ready", nil)];
  [self showLauncher];
}

- (void)onShowLibraryOverProgram {
  [self showLauncherAsSheet:YES];
}

@end

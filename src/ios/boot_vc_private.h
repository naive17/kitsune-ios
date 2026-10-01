/*
 * WineBootVC's state and the methods its files share.
 *
 * boot_vc.m          the view, the boot log and Wine's run
 * boot_vc_boot.m     startup: the runtime tree, JIT and the arena, the prefix
 * boot_vc_launch.m   the launcher, Steam launches, restarts and the session
 * boot_vc_controls.m the controls over a running program
 */
#ifndef KITSUNE_BOOT_VC_PRIVATE_H
#define KITSUNE_BOOT_VC_PRIVATE_H

#import "boot_vc.h"

#include "boot_status.h"
#include "input_overlay.h"
#include "launcher_vc.h"
#include "perf_hud.h"
#include "power.h"
#include "touch_gamepad.h"
#include "wine_boot.h"

#include <unistd.h>

extern int csops(pid_t, unsigned int, void *, size_t);

/* Whether a debugger (StikDebug) has set CS_DEBUGGED on this process. */
static inline BOOL CSDebugged(unsigned *flags_out) {
  unsigned flags = 0;
  BOOL ok = csops(getpid(), 0, &flags, sizeof(flags)) == 0 && (flags & 0x10000000u);
  if (flags_out) *flags_out = flags;
  return ok;
}

static inline NSString *RequestPath(void) {
  return [KitsunePersistentDocuments() stringByAppendingPathComponent:@"launch-request.json"];
}

/* A program to open after a restart (restartToOpen:), read back once JIT is
 * granted again (finishRuntimeSetup). */
static inline NSString *PendingLaunchPath(void) {
  return [KitsunePersistentDocuments() stringByAppendingPathComponent:@"pending-launch.plist"];
}

@interface WineBootVC () <UITextViewDelegate> {
  UITextView *_out;
  UILabel *_stage;
  UIProgressView *_bar;
  UIActivityIndicatorView *_spinner;
  UIButton *_details;
  UILabel *_pulse;
  UIButton *_runBtn;
  UIButton *_libraryBtn;
  NSMutableString *_log;
  NSUInteger _shownLen;
  BOOL _flushPending;
  BOOL _userScrolledBack;
  WineLauncherVC *_launcher;
  BOOL _launcherShown;
  NSArray<NSString *> *_argv;
  NSDictionary *_request;
  BOOL _jitFailed;
  dispatch_semaphore_t _jitRequestGate;
  BOOL _quickLaunchPending;
  NSDictionary *_pendingLaunch;          /* a program chosen before JIT was granted */
  NSString *_jitFailure;                 /* why the last JIT attempt failed; shown until the next */
  volatile double _returnedAt;           /* when the app came back during a JIT wait */
  WineInputOverlay *_input;
  UIVisualEffectView *_inputBarChrome;
  UIButton *_modeButton, *_padButton, *_ctrlButton, *_altButton, *_powerButton;
  NSArray<UIButton *> *_barButtons;
  NSArray<UIStackView *> *_barRows;
  UIButton *_showBar;
  NSArray<NSLayoutConstraint *> *_chromeBottom, *_chromeTop;
  WinePerfHUD *_hud;
  WineTouchGamepad *_pad;
  BOOL _padWanted;
  BOOL _landscape;                       /* the running program's orientation */
  CFAbsoluteTime _prepareStart;          /* when StikDebug started on the arena */
  WinePowerMode _modeBeforeBattery;
  NSString *_sessionBottle;              /* the bottle Wine runs, once it has booted */
  BOOL _wineStopped;                     /* Wine ran and exited; only a new process can start it */
  NSTimer *_sessionTimer;
  BOOL _sessionBusy;                     /* a program has run since the last launch */
  BOOL _sessionLandscape;                /* the orientation the session's desktop was made for */
  CFAbsoluteTime _sessionLaunchAt;
}
- (void)setPhase:(WineBootPhase)phase message:(NSString *)message;
- (void)say:(NSString *)line;
- (void)scheduleLogFlush;
- (void)showProgramOutput;
- (void)forceLandscapeIfAsked;
- (void)launchWine;
@end

@interface WineBootVC (Boot)
- (void)run;
- (void)arenaPrepared:(double)done;
- (void)finishRuntimeSetup;
- (void)cancelQueuedLaunch;
@end

@interface WineBootVC (Launch) <WineLauncherDelegate>
- (void)presentLauncherEarly;
- (void)showLauncher;
- (void)presentLauncher;
- (void)onShowLibrary;
- (void)startSessionTimer;
- (BOOL)requestJITFrom:(WineLauncherVC *)vc;
- (void)relaunch;
@end

@interface WineBootVC (Controls)
- (void)showInputLayer;
- (void)arrangeBar;
- (void)applyPad;
@end

#endif

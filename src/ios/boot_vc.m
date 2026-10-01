#import "boot_vc.h"

#import <GameController/GameController.h>

#include "app_library.h"
#include "boot_status.h"
#include "bottles.h"
#include "diagnostics.h"
#include "game_config.h"
#include "game_controller.h"
#include "input_overlay.h"
#include "jit_alloc.h"
#include "jit_arena.h"
#include "launch_request.h"
#include "launcher_settings.h"
#include "launcher_vc.h"
#include "log_tail.h"
#include "mach_excmon.h"
#include "pe_info.h"
#include "perf_hud.h"
#include "power.h"
#include "runtime_tree.h"
#include "session.h"
#include "steam_launch.h"
#include "task_manager.h"
#include "touch_gamepad.h"
#include "touch_gamepad_layout.h"
#include "wine_boot.h"
#include "wine_surface.h"

#include <dlfcn.h>
#include <mach/mach.h>
#include <os/proc.h>
#include <sys/stat.h>

/* Steam's client DLLs hold absolute self-references and must stay in the
 * executable arena with FEX's translations; 1024 MB is the measured need. */
#ifndef ARENA_MB
#define ARENA_MB 1024
#endif
#define WINE_SHARED_DATA_ADDR 0x120000000ull

extern int csops(pid_t, unsigned int, void *, size_t);

static BOOL CSDebugged(unsigned *flags_out) {
  unsigned flags = 0;
  BOOL ok = csops(getpid(), 0, &flags, sizeof(flags)) == 0 && (flags & 0x10000000u);
  if (flags_out) *flags_out = flags;
  return ok;
}

/* A launcher argv without its leading "wine". */
static NSArray<NSString *> *ProgramArgv(NSArray<NSString *> *argv) {
  return argv.count > 1 ? [argv subarrayWithRange:NSMakeRange(1, argv.count - 1)] : @[];
}

static NSString *RequestPath(void) {
  return [KitsunePersistentDocuments() stringByAppendingPathComponent:@"launch-request.json"];
}

/* A program to open after a restart (restartToOpen:), read back once JIT is
 * granted again (finishRuntimeSetup). */
static NSString *PendingLaunchPath(void) {
  return [KitsunePersistentDocuments() stringByAppendingPathComponent:@"pending-launch.plist"];
}

static NSString *ShaderCacheCensus(void) {
  NSString *dir = WineShaderCacheRoot();
  NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil];
  unsigned long long total = 0;
  for (NSString *n in names)
    total += [[NSFileManager.defaultManager attributesOfItemAtPath:[dir stringByAppendingPathComponent:n] error:nil] fileSize];
  return [NSString stringWithFormat:@"shader cache: %lu files, %llu KB", (unsigned long)names.count, total >> 10];
}

@interface WineBootVC () <UITextViewDelegate, WineLauncherDelegate>
- (void)arenaPrepared:(double)done;
@end

static void ArenaPrepared(double done, void *ctx) {
  [(__bridge WineBootVC *)ctx arenaPrepared:done];
}

static BOOL PhysicalControllerConnected(void) {
  for (GCController *c in GCController.controllers)
    if (c.extendedGamepad) return YES;
  return NO;
}

@implementation WineBootVC {
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

/* --- view ---------------------------------------------------------------- */

- (void)viewDidLoad {
  [super viewDidLoad];
  _jitRequestGate = dispatch_semaphore_create(0);
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  _log = [NSMutableString stringWithString:@"Kitsune\n\n"];

  _stage = [UILabel new];
  _stage.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
  _stage.textAlignment = NSTextAlignmentCenter;
  _stage.numberOfLines = 3;
  _stage.text = NSLocalizedString(@"Starting…", nil);
  _stage.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:_stage];

  _bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
  _bar.hidden = YES;
  _bar.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:_bar];

  _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
  _spinner.translatesAutoresizingMaskIntoConstraints = NO;
  [_spinner startAnimating];
  [self.view addSubview:_spinner];

  _details = [UIButton buttonWithType:UIButtonTypeSystem];
  [_details setTitle:NSLocalizedString(@"Details", nil) forState:UIControlStateNormal];
  _details.translatesAutoresizingMaskIntoConstraints = NO;
  [_details addTarget:self action:@selector(onToggleDetails) forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:_details];

  _out = [[UITextView alloc] initWithFrame:CGRectZero];
  _out.editable = NO;
  _out.selectable = YES;
  _out.delegate = self;
  _out.alwaysBounceVertical = YES;
  _out.hidden = YES;
  _out.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
  _out.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:_out];

  _pulse = [[UILabel alloc] initWithFrame:CGRectZero];
  _pulse.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
  _pulse.textColor = UIColor.secondaryLabelColor;
  _pulse.textAlignment = NSTextAlignmentCenter;
  _pulse.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:_pulse];

  _libraryBtn = [UIButton buttonWithType:UIButtonTypeSystem];
  [_libraryBtn setTitle:NSLocalizedString(@"Library", nil) forState:UIControlStateNormal];
  _libraryBtn.hidden = YES;
  _libraryBtn.translatesAutoresizingMaskIntoConstraints = NO;
  [_libraryBtn addTarget:self action:@selector(onShowLibrary) forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:_libraryBtn];

  _runBtn = [UIButton buttonWithType:UIButtonTypeSystem];
  _runBtn.translatesAutoresizingMaskIntoConstraints = NO;
  _runBtn.hidden = YES;
  _runBtn.backgroundColor = UIColor.systemBlueColor;
  [_runBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
  _runBtn.titleLabel.font = [UIFont boldSystemFontOfSize:17];
  _runBtn.layer.cornerRadius = 10;
  [_runBtn addTarget:self action:@selector(onRun) forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:_runBtn];

  UILayoutGuide *g = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [_spinner.centerXAnchor constraintEqualToAnchor:g.centerXAnchor],
    [_spinner.centerYAnchor constraintEqualToAnchor:g.centerYAnchor constant:-40],
    [_stage.topAnchor constraintEqualToAnchor:_spinner.bottomAnchor constant:18],
    [_stage.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:24],
    [_stage.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-24],
    [_bar.topAnchor constraintEqualToAnchor:_stage.bottomAnchor constant:12],
    [_bar.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:48],
    [_bar.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-48],
    [_pulse.topAnchor constraintEqualToAnchor:_bar.bottomAnchor constant:8],
    [_pulse.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:24],
    [_pulse.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-24],
    [_details.topAnchor constraintEqualToAnchor:_pulse.bottomAnchor constant:8],
    [_details.centerXAnchor constraintEqualToAnchor:g.centerXAnchor],
    [_out.topAnchor constraintEqualToAnchor:_details.bottomAnchor constant:4],
    [_out.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:10],
    [_out.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-10],
    [_out.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-72],
    [_runBtn.centerXAnchor constraintEqualToAnchor:g.centerXAnchor],
    [_runBtn.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-12],
    [_runBtn.heightAnchor constraintEqualToConstant:48],
    [_libraryBtn.centerXAnchor constraintEqualToAnchor:g.centerXAnchor],
    [_libraryBtn.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-20],
  ]];
  _out.text = _log;
  _shownLen = _log.length;

  KitsuneDiagInit();

  /* Controller input belongs to the game, not to UIKit focus navigation. */
  if (@available(iOS 18.0, *)) {
    GCEventInteraction *controllerEvents = [GCEventInteraction new];
    controllerEvents.handledEventTypes = GCUIEventTypeGamepad;
    [self.view addInteraction:controllerEvents];
  }

  /* CoreAnimation drops Metal layer contents while suspended; repaint on return. */
  [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                  object:nil queue:NSOperationQueue.mainQueue
                                              usingBlock:^(NSNotification *n __unused) {
    static void (*repaint)(void);
    if (!repaint) repaint = dlsym(RTLD_DEFAULT, "wineios_layer_repaint_all");
    if (repaint) repaint();
  }];

  /* A request left by an earlier run counts only when StikDebug started this
   * process for it. Otherwise Enable JIT would start that program. */
  if (!CSDebugged(NULL) && [NSFileManager.defaultManager removeItemAtPath:RequestPath() error:nil])
    KitsuneLog(@"REQUEST-DISCARDED left from an earlier run");

  /* The JIT handshake must run while StikDebug is still attached; the
   * foreground wait for the heavy boot happens after jit_detach. */
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [self run]; });
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  if (_launcherShown) return;
  _launcherShown = YES;
  [self presentLauncherEarly];
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
  [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
  [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> ctx __unused) {
    wine_surface_host_rotate();
  } completion:^(id<UIViewControllerTransitionCoordinatorContext> ctx __unused) {
    wine_surface_host_rotate();
  }];
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
  return _landscape ? UIInterfaceOrientationMaskLandscape : UIInterfaceOrientationMaskAll;
}

- (void)forceLandscapeIfAsked {
  if (!_landscape) return;
  if (@available(iOS 16.0, *)) {
    [self setNeedsUpdateOfSupportedInterfaceOrientations];
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
      if (![sc isKindOfClass:UIWindowScene.class]) continue;
      UIWindowSceneGeometryPreferencesIOS *p = [[UIWindowSceneGeometryPreferencesIOS alloc]
          initWithInterfaceOrientations:UIInterfaceOrientationMaskLandscapeRight];
      KitsuneLog(@"landscape: requesting LandscapeRight");
      [(UIWindowScene *)sc requestGeometryUpdateWithPreferences:p errorHandler:^(NSError *e) {
        KitsuneLog([NSString stringWithFormat:@"landscape: refused %@", e.localizedDescription ?: e]);
      }];
    }
  } else {
    [UIViewController attemptRotationToDeviceOrientation];
  }
}

/* --- stage and log ------------------------------------------------------- */

- (void)setPhase:(WineBootPhase)phase message:(NSString *)message {
  BOOL busy = phase == WineBootPhasePreparing || phase == WineBootPhaseWaitingJIT || phase == WineBootPhaseLaunching;
  dispatch_async(dispatch_get_main_queue(), ^{
    self->_stage.text = message;
    self->_stage.textColor = phase == WineBootPhaseFailed ? UIColor.systemRedColor : UIColor.labelColor;
    self->_bar.hidden = YES;
    if (phase == WineBootPhaseFailed) {
      self.view.backgroundColor = UIColor.systemBackgroundColor;
      self->_stage.hidden = NO;
      self->_details.hidden = NO;
    }
    if (busy) [self->_spinner startAnimating]; else [self->_spinner stopAnimating];
  });
  [WineBootStatus.shared setPhase:phase message:message];
}

- (void)onToggleDetails {
  _out.hidden = !_out.hidden;
  [_details setTitle:_out.hidden ? NSLocalizedString(@"Details", nil) : NSLocalizedString(@"Hide Details", nil) forState:UIControlStateNormal];
  if (!_out.hidden) { _shownLen = 0; _out.text = @""; [self scheduleLogFlush]; }
}

- (void)say:(NSString *)line {
  [_log appendFormat:@"%@\n", line];
  if (_log.length > 512 * 1024) [_log deleteCharactersInRange:NSMakeRange(0, _log.length - 256 * 1024)];
  dispatch_async(dispatch_get_main_queue(), ^{ if (!self->_out.hidden) [self scheduleLogFlush]; });
  KitsuneLog(line);
}

- (void)scheduleLogFlush {
  if (_flushPending) return;
  _flushPending = YES;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
    self->_flushPending = NO;
    NSUInteger have = self->_log.length;
    if (have < self->_shownLen) self->_shownLen = 0;
    if (have <= self->_shownLen) { [self pinToBottom]; return; }
    NSString *fresh = [self->_log substringFromIndex:self->_shownLen];
    self->_shownLen = have;
    NSTextStorage *ts = self->_out.textStorage;
    [ts beginEditing];
    [ts appendAttributedString:[[NSAttributedString alloc] initWithString:fresh attributes:@{
        NSFontAttributeName: self->_out.font, NSForegroundColorAttributeName: UIColor.labelColor }]];
    if (ts.length > 240000) [ts deleteCharactersInRange:NSMakeRange(0, ts.length - 120000)];
    [ts endEditing];
    [self pinToBottom];
  });
}

- (void)pinToBottom {
  if (_userScrolledBack || !_out.text.length) return;
  [_out scrollRangeToVisible:NSMakeRange(_out.text.length - 1, 1)];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)sv willDecelerate:(BOOL)more {
  if (!more) [self updateFollowState:sv];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)sv {
  [self updateFollowState:sv];
}

- (void)updateFollowState:(UIScrollView *)sv {
  CGFloat slack = sv.contentSize.height - sv.bounds.size.height;
  _userScrolledBack = slack > 8 && sv.contentOffset.y < slack - 8;
}

/* Lines a program printed, without Wine's own channels. */
- (void)showProgramOutput {
  NSString *raw = KitsuneLogTail(WineLogPath(), 128 * 1024);
  if (!raw.length) return;
  static NSRegularExpression *re;
  if (!re) re = [NSRegularExpression regularExpressionWithPattern:@"^[0-9a-f]{4}:" options:0 error:nil];
  NSMutableString *prog = [NSMutableString string];
  for (NSString *l in [raw componentsSeparatedByString:@"\n"]) {
    NSString *t = [l stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!t.length) continue;
    if ([re numberOfMatchesInString:l options:0 range:NSMakeRange(0, l.length)]) continue;
    if ([t hasPrefix:@"wine:"] || [t hasPrefix:@"==="] || [t hasPrefix:@"["]) continue;
    if ([t hasPrefix:@"err:"] || [t hasPrefix:@"fixme:"] || [t hasPrefix:@"warn:"]) continue;
    if ([t rangeOfString:@"Kitsune["].location != NSNotFound) continue;
    [prog appendFormat:@"%@\n", t];
  }
  if (!prog.length) return;
  [self say:@"--- program output ---"];
  for (NSString *l in [prog componentsSeparatedByString:@"\n"])
    if (l.length) [self say:[@"  " stringByAppendingString:l]];
}

/* --- boot ---------------------------------------------------------------- */

/* StikDebug runs the JIT script only when it is assigned to Kitsune in its
 * Scripts, for launches from its own app list; a copy in the app's Files
 * folder makes it importable there. */
static void PublishJITScript(void) {
  NSString *bundled = [NSBundle.mainBundle pathForResource:@"kitsune" ofType:@"js"];
  NSString *copy = [KitsunePersistentDocuments() stringByAppendingPathComponent:@"kitsune.js"];
  NSData *script = bundled ? [NSData dataWithContentsOfFile:bundled] : nil;
  if (script && ![[NSData dataWithContentsOfFile:copy] isEqualToData:script])
    [script writeToFile:copy atomically:YES];
}

- (void)run {
  KitsuneDiagPolicy policy = KitsuneDiagPolicyFor(KitsuneDiagLevelFromEnv());
  [self setPhase:WineBootPhasePreparing message:NSLocalizedString(@"Starting…", nil)];
  PublishJITScript();
  [self say:[NSString stringWithFormat:@"device: %@ / iOS %@", UIDevice.currentDevice.model, UIDevice.currentDevice.systemVersion]];

  /* The previous run's wine log: its tail is shown, and the file is archived
   * so Wine cannot truncate it. */
  {
    KitsuneLog([NSString stringWithFormat:@"STARTUP os_pid=%d app=%s %s", getpid(), __DATE__, __TIME__]);
    struct stat st;
    if (stat(WineLogPath().fileSystemRepresentation, &st) == 0 && st.st_size > 0) {
      if (policy.previous_log_preview) {
        NSString *prev = KitsuneLogTail(WineLogPath(), 128 * 1024);
        [self say:[NSString stringWithFormat:@"previous wine log: %lu characters", (unsigned long)prev.length]];
        [self showProgramOutput];
        [_log appendString:prev];
      }
      NSString *archive = [WineLogPath() stringByAppendingFormat:@".previous-%@", NSUUID.UUID.UUIDString];
      NSError *err = nil;
      if (![NSFileManager.defaultManager moveItemAtPath:WineLogPath() toPath:archive error:&err]) {
        [self say:[NSString stringWithFormat:@"cannot preserve previous log: %@", err.localizedDescription]];
        return;
      }
      /* Keep one archived run; unbounded archives filled the phone once. */
      NSString *dir = WineLogPath().stringByDeletingLastPathComponent;
      NSString *stem = [WineLogPath().lastPathComponent stringByAppendingString:@".previous-"];
      for (NSString *n in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil])
        if ([n hasPrefix:stem] && ![n isEqualToString:archive.lastPathComponent])
          [NSFileManager.defaultManager removeItemAtPath:[dir stringByAppendingPathComponent:n] error:nil];
    }
  }

  {
    unsigned flags = 0;
    BOOL dbg = CSDebugged(&flags);
    [self say:[NSString stringWithFormat:@"CS_DEBUGGED: %@ (cs_flags=0x%08x)", dbg ? @"yes" : @"no", flags]];
  }
  (void)WineLogPathC();
  if (policy.mach_exc_monitor) MachExcMon_Install(KitsuneHeartbeatFd());
  GameController_Start();

  /* The Wine tree is installed before JIT: it is only file copying, and
   * installing Steam needs the tree, so it must not wait for a program to be
   * started. The launcher offers nothing to run while this is Preparing. */
  [self setPhase:WineBootPhasePreparing message:NSLocalizedString(@"Checking runtime…", nil)];
  if (![self ensureRuntimePayload]) {
    [self setPhase:WineBootPhaseFailed message:NSLocalizedString(@"Wine runtime missing. Install the full build.", nil)];
    return;
  }

  /* The arena needs StikDebug attached with the Kitsune script. Enable JIT
   * and Play pass the script along; StikDebug's own app list passes it only
   * when it is assigned to Kitsune there, and otherwise just sets the debug
   * flag, which is why a missing script is retried rather than fatal. */
  {
    char aerr[256] = {0};
    unsigned long arena_mb = ARENA_MB;
    const char *e = getenv("KITSUNE_ARENA_MB");
    size_t pinned = ios_jit_arena_pinned_len();
    if (e && atol(e) >= 128) arena_mb = (unsigned long)atol(e);
    else if (pinned) arena_mb = (unsigned long)(pinned >> 20);
    size_t want = (size_t)arena_mb << 20;
    BOOL keepout = NO;

    for (;;) {
      unsigned flags = 0;
      if (!CSDebugged(&flags)) {
        [self waitForDebugger:flags];
        continue;
      }
      if (!keepout) {
        keepout = YES;
        if (!ios_jit_arena_reserve((void *)WINE_SHARED_DATA_ADDR, 0x10000, aerr, sizeof(aerr)))
          KitsuneLog([NSString stringWithFormat:@"KEEPOUT-FAIL %s", aerr]);
      }
      [self showBeforePause:NSLocalizedString(@"Enabling JIT…", nil)];
      ios_jit_arena_set_progress(ArenaPrepared, (__bridge void *)self);
      _prepareStart = CFAbsoluteTimeGetCurrent();
      int rc = ios_jit_arena_init(want, aerr, sizeof(aerr));
      if (rc < 0) {
        [self say:[NSString stringWithFormat:@"JIT script not attached: %s", aerr]];
        KitsuneLog([NSString stringWithFormat:@"JIT-NO-SCRIPT %s", aerr]);
        rc = [self retryUntilScriptAnswers:want error:aerr length:sizeof(aerr)];
      }
      if (rc > 0) {
        void *lo = NULL; size_t sz = 0; ptrdiff_t delta = 0;
        ios_jit_arena_bounds(&lo, &sz, &delta);
        [self say:[NSString stringWithFormat:@"JIT arena: %zu MB at %p", sz >> 20, lo]];
        KitsuneLog([NSString stringWithFormat:@"ARENA-OK %zuMB %p-%p delta=%lx", sz >> 20, lo, (char *)lo + sz, (long)delta]);
        KitsuneLog([NSString stringWithUTF8String:ios_jit_arena_pin_note()]);
        KitsuneLog(KitsuneMemLine(@"after-arena"));
        if (policy.boot_probes) {
          WineBootDumpVM("after-arena", KitsuneLogC);
          WineBootPreflightUnixLibs([NSBundle.mainBundle.bundlePath
              stringByAppendingPathComponent:@"lib/wine/aarch64-unix"].fileSystemRepresentation, KitsuneLogC);
          WineBootProbeFixedMap(KitsuneLogC);
        }
      } else {
        [self say:[NSString stringWithFormat:@"JIT arena failed: %s", aerr]];
        KitsuneLog([NSString stringWithFormat:@"ARENA-FAIL %s", aerr]);
        KitsuneLog([NSString stringWithUTF8String:ios_jit_arena_pin_note()]);
        _jitFailed = YES;
      }
      break;
    }
    _jitFailure = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ self->_quickLaunchPending = NO; });
  }
  ios_jit_arena_release_reserved();

  /* Prove the arena executes before handing anything to Wine. */
  {
    void *exec = NULL, *write = NULL;
    if (ios_jit_arena_available() && ios_jit_arena_alloc(64, 64, &exec, &write)) {
      *(uint32_t *)write = 0xd65f03c0;   /* ret: fresh arena pages hold only StikDebug's marker byte */
      ios_jit_arena_publish(exec, 64);
      KitsuneLogC("ARENA-EXEC about to call");
      ((void (*)(void))exec)();
      KitsuneLog(@"ARENA-EXEC ok");
    } else {
      KitsuneLog(@"ARENA-EXEC skipped: no arena");
    }
  }
  {
    char derr[256] = {0};
    [self say:jit_detach(derr, sizeof(derr)) ? @"detached from debugger"
                                             : [NSString stringWithFormat:@"detach failed: %s", derr]];
  }
  if (_jitFailed) {
    [self setPhase:WineBootPhaseFailed message:NSLocalizedString(@"JIT setup failed. Opening a program restarts Kitsune.", nil)];
    KitsuneLog(@"HALTED-NO-JIT");
    return;
  }
  [self waitForForeground];
  [self finishRuntimeSetup];
}

/* Runs between StikDebug's preparation steps, while the app briefly runs:
 * logs the pace and draws the bar before the next step stops the app. */
- (void)arenaPrepared:(double)done {
  KitsuneLog([NSString stringWithFormat:@"JIT-PREP %.0f%% after %.1fs", done * 100, CFAbsoluteTimeGetCurrent() - _prepareStart]);
  [WineBootStatus.shared setProgress:done];
  dispatch_sync(dispatch_get_main_queue(), ^{
    self->_bar.hidden = NO;
    [self->_bar setProgress:(float)done animated:NO];
  });
  dispatch_sync(dispatch_get_main_queue(), ^{ [CATransaction flush]; });
}

/* The handshake stops the whole process while StikDebug prepares the arena,
 * which it does after switching back to the app. Put the reason on screen
 * first: the status goes through two main-queue hops before it is drawn. */
- (void)showBeforePause:(NSString *)message {
  [self setPhase:WineBootPhasePreparing message:message];
  dispatch_sync(dispatch_get_main_queue(), ^{});
  dispatch_sync(dispatch_get_main_queue(), ^{ [CATransaction flush]; });
}

/* Until StikDebug attaches: Enable JIT and Play open it, and it can also be
 * started from its own app list, so the debug flag is checked meanwhile. */
- (void)waitForDebugger:(unsigned)flags {
  [self say:[NSString stringWithFormat:@"JIT is not enabled (cs_flags=0x%08x)", flags]];
  KitsuneLog([NSString stringWithFormat:@"JIT-NOT-ENABLED cs_flags=0x%08x", flags]);
  [self setPhase:WineBootPhaseNeedsJIT message:_jitFailure ?: NSLocalizedString(@"JIT is off.", nil)];
  while (dispatch_semaphore_wait(_jitRequestGate, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC)))
    if (CSDebugged(NULL)) return;
  if ([self pollJIT:^BOOL { return CSDebugged(NULL); }]) return;
  _jitFailure = NSLocalizedString(@"JIT didn't turn on. Check StikDebug and try again.", nil);
  dispatch_async(dispatch_get_main_queue(), ^{ [self cancelQueuedLaunch]; });
}

/* A program chosen before a JIT attempt that failed is dropped with it, so a
 * later Enable JIT does not start it. */
- (void)cancelQueuedLaunch {
  _quickLaunchPending = NO;
  _pendingLaunch = nil;
  [NSFileManager.defaultManager removeItemAtPath:RequestPath() error:nil];
}

/* The debug flag is set but nothing answers the handshake: StikDebug started
 * the app without the script. Retries until an attach with it arrives, which
 * Enable JIT and Play request. */
- (int)retryUntilScriptAnswers:(size_t)want error:(char *)err length:(size_t)len {
  NSString *prompt = NSLocalizedString(@"JIT needs the Kitsune script. Tap Enable JIT.", nil);
  [self setPhase:WineBootPhaseNeedsJIT message:prompt];
  dispatch_async(dispatch_get_main_queue(), ^{ [self showLauncher]; });
  double asked = 0;
  int rc;
  while ((rc = ios_jit_arena_init(want, err, len)) < 0) {
    if (!dispatch_semaphore_wait(_jitRequestGate, dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC)))
      asked = CFAbsoluteTimeGetCurrent();
    if (asked > 0 && CFAbsoluteTimeGetCurrent() - asked > 90) {
      asked = 0;
      [self setPhase:WineBootPhaseNeedsJIT message:prompt];
      dispatch_async(dispatch_get_main_queue(), ^{ [self cancelQueuedLaunch]; });
    }
  }
  return rc;
}

/* Polls `granted` for up to 90 s while StikDebug works, and for 5 s once the
 * user is back in the app without it. */
- (BOOL)pollJIT:(BOOL (^)(void))granted {
  _returnedAt = 0;
  id observer = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
      object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n __unused) {
    if (self->_returnedAt == 0) self->_returnedAt = CFAbsoluteTimeGetCurrent();
  }];
  BOOL ok = NO;
  for (unsigned attempt = 0; attempt < 900 && !(ok = granted()); ++attempt) {
    double back = _returnedAt;
    if (back > 0 && CFAbsoluteTimeGetCurrent() - back > 5.0) break;
    usleep(100000);
  }
  [NSNotificationCenter.defaultCenter removeObserver:observer];
  return ok;
}

/* Wine's boot pegs a core for minutes; suspended in the background it is
 * killed by the watchdog. Wait until the app is frontmost. */
- (void)waitForForeground {
  __block BOOL active = NO;
  dispatch_sync(dispatch_get_main_queue(), ^{
    active = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
  });
  if (active) return;
  [self say:@"JIT ready; waiting for the foreground before booting Wine"];
  [self setPhase:WineBootPhaseWaitingJIT message:NSLocalizedString(@"JIT is on. Switch back to Kitsune.", nil)];
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  __block id tok = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                                    object:nil queue:NSOperationQueue.mainQueue
                                                                usingBlock:^(NSNotification *n __unused) {
    [NSNotificationCenter.defaultCenter removeObserver:tok];
    dispatch_semaphore_signal(sem);
  }];
  dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
}

/* The tree the app boots from: the installed one when the bundled tree is
 * absent or the same version, else the bundled one is installed. */
- (BOOL)ensureRuntimePayload {
  NSString *root = WineTreeRoot();
  NSString *bootstrap = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Bootstrap"];
  NSString *bundledTree = [bootstrap stringByAppendingPathComponent:@"wine"];
  NSString *bundled = KitsuneTreeVersion(bundledTree);
  NSString *have = KitsuneTreeVersion(root);
  [self say:[NSString stringWithFormat:@"tree: installed=%@ bundled=%@", have ?: @"(none)", bundled ?: @"(none)"]];

  if (bundled.length && !KitsuneTreeMatches(root, bundled)) {
    NSError *error = nil;
    [self say:@"installing the bundled Wine tree"];
    [self setPhase:WineBootPhasePreparing message:NSLocalizedString(@"Installing runtime…", nil)];
    if (!KitsuneInstallTree(bundledTree, root, bundled, &error)) {
      [self say:[NSString stringWithFormat:@"tree install failed: %@", error.localizedDescription]];
      return NO;
    }
  } else if (!KitsuneTreeMatches(root, have)) {
    [self say:@"No Wine tree installed. Install the full build once, or sync the tree from a Mac."];
    return NO;
  }
  return YES;
}

- (void)finishRuntimeSetup {
  KitsuneDiagPolicy policy = KitsuneDiagPolicyFor(KitsuneDiagLevelFromEnv());

  /* A queued request (Play, or one pushed from a Mac) selects the program. It is
   * consumed only now, after JIT succeeded, so a failed attach cannot lose it. */
  NSString *requestFile = RequestPath();
  if ([NSFileManager.defaultManager fileExistsAtPath:requestFile]) {
    NSString *reason = nil;
    NSNumber *size = [[NSFileManager.defaultManager attributesOfItemAtPath:requestFile error:nil] objectForKey:NSFileSize];
    NSData *data = size.unsignedLongLongValue <= 32768 ? [NSData dataWithContentsOfFile:requestFile] : nil;
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    _request = KitsuneValidateLaunchRequest(json, KitsunePersistentDocuments(), &reason);
    pe_info info;
    char peError[256] = {0};
    if (_request && (pe_info_read([_request[@"exe"] fileSystemRepresentation], &info, peError, sizeof(peError)) || info.is_dll)) {
      reason = [NSString stringWithFormat:NSLocalizedString(@"not an executable PE: %s", nil), peError];
      _request = nil;
    }
    if (!_request) {
      [self say:[@"launch request rejected: " stringByAppendingString:reason ?: @"invalid request"]];
      [self setPhase:WineBootPhaseFailed message:[NSLocalizedString(@"Launch request rejected: ", nil) stringByAppendingString:reason ?: NSLocalizedString(@"invalid request", nil)]];
      return;
    }
    NSString *receipt = [requestFile stringByAppendingFormat:@".consumed-%@", NSUUID.UUID.UUIDString];
    if (![NSFileManager.defaultManager moveItemAtPath:requestFile toPath:receipt error:nil]) {
      [self say:@"launch request rejected: cannot consume it"];
      return;
    }
    WineBootSelectBottle(_request[@"bottle"]);
    [self say:[NSString stringWithFormat:@"launch: %@ (%s) in %@", [_request[@"exe"] lastPathComponent],
               pe_arch_name(info.arch), WineBootPrefix()]];
    setenv("WINEDEBUG", [_request[@"bottle"] isEqualToString:@"Steam"] ? policy.winedebug_steam : policy.winedebug_other, 1);
    setenv("KITSUNE_NO_GUEST_DUMP", "1", 1);
    setenv("KITSUNE_FAULT_STACKS", "1", 1);
    NSDictionary *env = _request[@"env"];
    for (NSString *k in env) {
      setenv(k.UTF8String, ((NSString *)env[k]).UTF8String, 1);
      [self say:[NSString stringWithFormat:@"env %@=%@", k, env[k]]];
    }
  }

  /* A program chosen before a restart: in another bottle, or after Wine stopped. */
  NSDictionary *pending = [NSDictionary dictionaryWithContentsOfFile:PendingLaunchPath()];
  [NSFileManager.defaultManager removeItemAtPath:PendingLaunchPath() error:nil];
  if (pending && !_request && [pending[@"argv"] isKindOfClass:NSArray.class] && KitsuneBottleNameValid(pending[@"bottle"])) {
    if (![pending[@"bottle"] isEqualToString:KITSUNE_DEFAULT_BOTTLE]) WineBootSelectBottle(pending[@"bottle"]);
    [self say:[NSString stringWithFormat:@"after restart: %@ in %@", pending[@"label"], pending[@"bottle"]]];
    _pendingLaunch = pending;
  }

  /* The prefix: rebuilt from the tree's template when it predates the tree. */
  NSString *pe = [WineTreeRoot() stringByAppendingPathComponent:@"lib/wine/aarch64-windows"];
  NSString *reg = [WineBootPrefix() stringByAppendingPathComponent:@"system.reg"];
  NSString *treeVersion = KitsuneTreeVersion(WineTreeRoot()) ?: @"";
  NSString *stampFile = [WineBootPrefix() stringByAppendingPathComponent:@".tree-stamp"];
  BOOL havePrefix = [NSFileManager.defaultManager fileExistsAtPath:reg];
  BOOL defaultPrefix = [WineBootPrefix() isEqualToString:KitsuneBottlePath(KitsunePersistentDocuments(), nil)];
  if (havePrefix) {
    NSString *stamp = [[NSString stringWithContentsOfFile:stampFile encoding:NSUTF8StringEncoding error:nil]
                       stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *sysreg = [NSString stringWithContentsOfFile:reg encoding:NSUTF8StringEncoding error:nil];
    BOOL stale = ![sysreg containsString:@"CP 4030"] || ![stamp isEqualToString:treeVersion];
    /* Named bottles hold installed programs and saves; they are never rebuilt
     * automatically. The default prefix holds nothing of the user's. */
    if (stale && !defaultPrefix)
      KitsuneLog([NSString stringWithFormat:@"bottle %@ was made with runtime %@, running %@; kept as is",
                  WineBootPrefix().lastPathComponent, stamp.length ? stamp : @"unknown", treeVersion]);
    if (stale && defaultPrefix) {
      [self say:@"prefix predates this tree; rebuilding it"];
      [NSFileManager.defaultManager removeItemAtPath:WineBootPrefix() error:nil];
      havePrefix = NO;
    }
  }
  if (!havePrefix) {
    NSString *tmpl = [WineTreeRoot() stringByAppendingPathComponent:@"prefix-template"];
    [self setPhase:WineBootPhasePreparing message:NSLocalizedString(@"Creating default bottle…", nil)];
    if ([NSFileManager.defaultManager fileExistsAtPath:[tmpl stringByAppendingPathComponent:@"system.reg"]]) {
      [NSFileManager.defaultManager createDirectoryAtPath:WineBootPrefix().stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES attributes:nil error:nil];
      [NSFileManager.defaultManager removeItemAtPath:WineBootPrefix() error:nil];
      if ([NSFileManager.defaultManager copyItemAtPath:tmpl toPath:WineBootPrefix() error:nil]) {
        [treeVersion writeToFile:stampFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
        havePrefix = [NSFileManager.defaultManager fileExistsAtPath:reg];
        [self say:@"installed the prefix from the tree's template"];
      }
    }
  }
  if (havePrefix) {
    KitsuneRepairBottle(WineBootPrefix(), WineTreeRoot());
    NSString *dd = [WineBootPrefix() stringByAppendingPathComponent:@"dosdevices"];
    NSDictionary *want = @{ @"c:": @"../drive_c", @"z:": @"/" };
    [NSFileManager.defaultManager createDirectoryAtPath:dd withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *link in want) {
      NSString *lp = [dd stringByAppendingPathComponent:link];
      if ([[NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:lp error:nil] isEqualToString:want[link]]) continue;
      [NSFileManager.defaultManager removeItemAtPath:lp error:nil];
      [NSFileManager.defaultManager createSymbolicLinkAtPath:lp withDestinationPath:want[link] error:nil];
    }
  }

  /* Without a prefix, Set Up Default Bottle runs wineboot to make one. */
  if (!havePrefix) _argv = @[ @"wine", [pe stringByAppendingPathComponent:@"wineboot.exe"], @"--init" ];
  KitsuneLog(havePrefix ? @"READY-LAUNCHER" : @"READY-WINEBOOT-INIT");
  if (!havePrefix)
    [self setPhase:WineBootPhaseFailed message:NSLocalizedString(@"Wine runtime incomplete. Install the full build.", nil)];

  dispatch_async(dispatch_get_main_queue(), ^{
    if (!havePrefix) {
      self->_runBtn.hidden = NO;
      [self->_runBtn setTitle:NSLocalizedString(@"  Set Up Default Bottle  ", nil) forState:UIControlStateNormal];
      return;
    }
    if (self->_request) {
      NSString *exe = self->_request[@"exe"];
      NSMutableArray *args = [NSMutableArray arrayWithObjects:@"wine", exe, nil];
      [args addObjectsFromArray:self->_request[@"args"]];
      [self launcher:nil runArgv:args workingDir:exe.stringByDeletingLastPathComponent bottle:self->_request[@"bottle"]
                 gui:YES label:exe.lastPathComponent];
      return;
    }
    if (self->_pendingLaunch) {
      NSDictionary *p = self->_pendingLaunch;
      self->_pendingLaunch = nil;
      [self setPhase:WineBootPhaseReady message:NSLocalizedString(@"Ready", nil)];
      [self launcher:nil runArgv:p[@"argv"] workingDir:p[@"cwd"] bottle:p[@"bottle"] gui:[p[@"gui"] boolValue] label:p[@"label"]];
      return;
    }
    [self presentLauncher];
  });
}

- (void)onRun {
  _runBtn.hidden = YES;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [self launchWine]; });
}

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
    if ([self runInSession:[@[ @"wine", exe ] arrayByAddingObjectsFromArray:request[@"args"]]
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
  if (![KitsuneSteamRequestData(appID, options, KitsunePersistentDocuments()) writeToFile:RequestPath() options:NSDataWritingAtomic error:&error]) {
    [vc report:NSLocalizedString(@"Can't Launch", nil) message:error.localizedDescription];
    return;
  }
  [NSFileManager.defaultManager removeItemAtPath:
      [KitsunePersistentDocuments() stringByAppendingPathComponent:@"dxmt-gpu-debug.txt"] error:nil];
  [self fitSteamGameToScreen:appID];
  _quickLaunchPending = YES;
  if (jitReady) [self setPhase:WineBootPhaseLaunching message:[NSString stringWithFormat:NSLocalizedString(@"Starting %@", nil), name ?: NSLocalizedString(@"Steam", nil)]];
  else [self setPhase:WineBootPhaseWaitingJIT message:NSLocalizedString(@"Enabling JIT…", nil)];
  KitsuneLog([NSString stringWithFormat:@"PLAY app=%@ textures=%ld cap=%d steam=%@ diag=%ld",
                 appID ?: @"client", (long)options.textures, options.frameCap,
                 options.steamVisible ? @"visible" : @"hidden", (long)options.diag]);
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
    if (![KitsuneSteamRequestData(appID, options, KitsunePersistentDocuments()) writeToFile:RequestPath() options:NSDataWritingAtomic error:&error])
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

/* --- in-session controls ------------------------------------------------- */

- (void)showInputLayer {
  if (_input) return;
  /* A running program gets the screen: no boot status behind its windows. */
  self.view.backgroundColor = UIColor.blackColor;
  for (UIView *v in @[ _stage, _spinner, _bar, _details, _out, _libraryBtn ]) v.hidden = YES;
  _input = [[WineInputOverlay alloc] initWithFrame:self.view.bounds];
  _input.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  _input.layer.zPosition = 2000;   /* above the Wine layers at 1000 */
  [self.view addSubview:_input];

  UIButton *(^mk)(NSString *, NSString *, SEL) = ^UIButton *(NSString *symbol, NSString *fallback, SEL action) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    if (@available(iOS 26.0, *)) b.configuration = [UIButtonConfiguration glassButtonConfiguration];
    UIImage *img = [UIImage systemImageNamed:symbol];
    if (img) {
      [b setImage:img forState:UIControlStateNormal];
      b.tintColor = UIColor.whiteColor;
    } else {
      [b setTitle:fallback forState:UIControlStateNormal];
      [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
      b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    }
    b.accessibilityLabel = fallback;
    b.layer.cornerRadius = 15;
    b.clipsToBounds = YES;
    [b.widthAnchor constraintEqualToConstant:KITSUNE_BAR_BUTTON_WIDTH].active = YES;
    [b.heightAnchor constraintEqualToConstant:30].active = YES;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
  };
  _modeButton = mk(@"hand.tap", NSLocalizedString(@"mode", nil), @selector(onToggleMode));
  _padButton = mk(@"gamecontroller", NSLocalizedString(@"controller", nil), @selector(onTogglePad));
  _ctrlButton = mk(@"control", NSLocalizedString(@"ctrl", nil), @selector(onCtrl));
  _altButton = mk(@"option", NSLocalizedString(@"alt", nil), @selector(onAlt));
  _powerButton = mk(@"leaf", NSLocalizedString(@"eco", nil), @selector(onTogglePower));
  _barButtons = @[
      mk(@"square.grid.2x2",         NSLocalizedString(@"library", nil), @selector(onShowLibraryOverProgram)),
      _modeButton,
      _padButton,
      mk(@"keyboard",                NSLocalizedString(@"kbd", nil),  @selector(onToggleKeyboard)),
      mk(@"escape",                  NSLocalizedString(@"esc", nil),  @selector(onEsc)),
      mk(@"arrow.right.to.line",     NSLocalizedString(@"tab", nil),  @selector(onTab)),
      _ctrlButton,
      _altButton,
      mk(@"1.magnifyingglass",       NSLocalizedString(@"1:1", nil),  @selector(onResetZoom)),
      mk(@"list.bullet.rectangle",   NSLocalizedString(@"apps", nil), @selector(onShowTasks)),
      _powerButton,
      mk(@"xmark",                   NSLocalizedString(@"hide", nil), @selector(onHideInput)),
  ];
  NSAssert(_barButtons.count == KITSUNE_BAR_BUTTONS, @"the pad layout reserves room for %d bar buttons", KITSUNE_BAR_BUTTONS);
  UIStackView *(^row)(void) = ^UIStackView *(void) {
    UIStackView *r = [UIStackView new];
    r.axis = UILayoutConstraintAxisHorizontal;
    r.alignment = UIStackViewAlignmentCenter;
    r.spacing = 2;
    return r;
  };
  _barRows = @[ row(), row() ];
  UIStackView *bar = [[UIStackView alloc] initWithArrangedSubviews:_barRows];
  bar.axis = UILayoutConstraintAxisVertical;
  bar.alignment = UIStackViewAlignmentCenter;
  bar.spacing = 2;
  bar.layoutMarginsRelativeArrangement = YES;
  bar.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(4, 8, 4, 8);
  bar.translatesAutoresizingMaskIntoConstraints = NO;
  [self arrangeBar];

  UIVisualEffect *material;
  if (@available(iOS 26.0, *)) {
    UIGlassEffect *glass = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
    glass.interactive = YES;
    material = glass;
  } else {
    material = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark];
  }
  UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:material];
  blur.translatesAutoresizingMaskIntoConstraints = NO;
  blur.layer.cornerRadius = 19;
  blur.clipsToBounds = YES;
  blur.layer.zPosition = 2001;
  [self.view addSubview:blur];
  [blur.contentView addSubview:bar];
  _inputBarChrome = blur;

  _showBar = [UIButton buttonWithType:UIButtonTypeSystem];
  [_showBar setImage:[UIImage systemImageNamed:@"keyboard.chevron.compact.down"] forState:UIControlStateNormal];
  _showBar.tintColor = UIColor.whiteColor;
  _showBar.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.4];
  _showBar.layer.cornerRadius = 14;
  _showBar.layer.zPosition = 2001;
  _showBar.translatesAutoresizingMaskIntoConstraints = NO;
  _showBar.hidden = YES;
  [_showBar addTarget:self action:@selector(onShowInput) forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:_showBar];

  _hud = [WinePerfHUD new];
  _hud.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:_hud];

  UILayoutGuide *g = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [bar.topAnchor constraintEqualToAnchor:blur.contentView.topAnchor],
    [bar.bottomAnchor constraintEqualToAnchor:blur.contentView.bottomAnchor],
    [bar.leadingAnchor constraintEqualToAnchor:blur.contentView.leadingAnchor],
    [bar.trailingAnchor constraintEqualToAnchor:blur.contentView.trailingAnchor],
    [blur.centerXAnchor constraintEqualToAnchor:g.centerXAnchor],
    [_showBar.widthAnchor constraintEqualToConstant:36],
    [_showBar.heightAnchor constraintEqualToConstant:28],
  ]];
  /* The pad owns the bottom corners and the screen edges, so while it is shown
   * the bar, its show button and the overlay sit at the top centre, the band
   * KitsunePadReservedTop keeps clear. */
  _chromeBottom = @[
    [blur.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-8],
    [_showBar.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-8],
    [_showBar.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-8],
    [_hud.topAnchor constraintEqualToAnchor:g.topAnchor constant:6],
    [_hud.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:8],
  ];
  _chromeTop = @[
    [blur.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
    [_showBar.centerXAnchor constraintEqualToAnchor:g.centerXAnchor],
    [_showBar.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
    [_hud.topAnchor constraintEqualToAnchor:blur.bottomAnchor constant:6],
    [_hud.centerXAnchor constraintEqualToAnchor:g.centerXAnchor],
  ];
  [NSLayoutConstraint activateConstraints:_chromeBottom];

  NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
  _input.lookSensitivity = KitsuneLookSensitivityStored(ud);
  _Static_assert(WinePointerTouch == 0 && WinePointerTrackpad == 1 && WinePointerLook == 2,
                 "KitsunePointerModeStored returns these values");
  _input.pointerMode = (WinePointerMode)KitsunePointerModeStored(ud);
  [self updateModeButton];
  [self updateHUD];
  [self updatePowerButton];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updatePowerButton)
                                             name:WinePowerDidChangeNotification object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateHUD)
                                             name:NSUserDefaultsDidChangeNotification object:nil];

  _padWanted = KitsuneTouchPadStored(ud) && [_request[@"args"] containsObject:@"-applaunch"];
  __weak WineBootVC *weakSelf = self;
  for (NSNotificationName name in @[ GCControllerDidConnectNotification, GCControllerDidDisconnectNotification ])
    [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n __unused) { [weakSelf applyPad]; }];
  [self applyPad];
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  [self arrangeBar];
}

/* One row when the safe width holds every button, else two. */
- (void)arrangeBar {
  if (!_barButtons) return;
  UIEdgeInsets inset = self.view.safeAreaInsets;
  BOOL oneRow = KitsuneBarRows(self.view.bounds.size.width - inset.left - inset.right) == 1;
  NSUInteger split = oneRow ? _barButtons.count : (_barButtons.count + 1) / 2;
  for (NSUInteger i = 0; i < _barButtons.count; i++) {
    UIStackView *target = _barRows[i < split ? 0 : 1];
    if (_barButtons[i].superview != target) [target addArrangedSubview:_barButtons[i]];
  }
  _barRows[1].hidden = oneRow;
}

- (void)onTogglePad {
  _padWanted = !_padWanted;
  [self applyPad];
}

/* A physical controller takes over from the pad; the pad returns when the
 * last one disconnects. */
- (void)applyPad {
  BOOL show = _padWanted && !PhysicalControllerConnected();
  if (show && !_pad) {
    _pad = [[WineTouchGamepad alloc] initWithFrame:self.view.bounds];
    _pad.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _pad.layer.zPosition = 2000;
    [self.view addSubview:_pad];
  }
  _pad.hidden = !show;
  _padButton.tintColor = _padWanted ? UIColor.systemYellowColor : UIColor.whiteColor;
  NSArray<NSLayoutConstraint *> *off = show ? _chromeBottom : _chromeTop;
  NSArray<NSLayoutConstraint *> *on = show ? _chromeTop : _chromeBottom;
  [NSLayoutConstraint deactivateConstraints:off];
  [NSLayoutConstraint activateConstraints:on];
}

/* Switches to Battery, live; a second tap restores the mode chosen before. */
- (void)onTogglePower {
  WinePower *power = WinePower.shared;
  if (power.userMode == WinePowerBattery) {
    power.userMode = _modeBeforeBattery;
  } else {
    _modeBeforeBattery = power.userMode;
    power.userMode = WinePowerBattery;
  }
  [self updatePowerButton];
}

- (void)updatePowerButton {
  _powerButton.tintColor = WinePower.shared.effectiveMode == WinePowerBattery ? UIColor.systemGreenColor : UIColor.whiteColor;
  [self updateHUD];
}

/* The overlay's switch is in Settings, which the Library shows over a program.
 * It is shown whenever logging or Battery is on or iOS is throttling a hot
 * phone, which it announces, even with the switch off. setVisible restarts the
 * frame count, so only on a change. Thermal changes arrive through
 * WinePowerDidChangeNotification. */
- (void)updateHUD {
  BOOL want = KitsunePerfHUDStored(NSUserDefaults.standardUserDefaults) || KitsuneDiagLevelFromEnv() != KitsuneDiagOff ||
              WinePower.shared.effectiveMode == WinePowerBattery ||
              NSProcessInfo.processInfo.thermalState >= NSProcessInfoThermalStateSerious;
  if (_hud.hidden == want) [_hud setVisible:want];
}

- (void)updateModeButton {
  static NSString *const symbols[] = { @"hand.tap", @"cursorarrow.motionlines", @"scope" };
  static NSString *const titles[] = { @"tap", @"pad", @"look" };
  NSInteger m = _input.pointerMode;
  UIImage *img = [UIImage systemImageNamed:symbols[m]];
  if (img) [_modeButton setImage:img forState:UIControlStateNormal];
  else [_modeButton setTitle:NSLocalizedString(titles[m], nil) forState:UIControlStateNormal];
  _modeButton.accessibilityLabel = NSLocalizedString(titles[m], nil);
}

- (void)onToggleMode {
  _input.pointerMode = (WinePointerMode)((_input.pointerMode + 1) % 3);
  [NSUserDefaults.standardUserDefaults setInteger:_input.pointerMode forKey:KITSUNE_KEY_POINTER_MODE];
  [self updateModeButton];
}
- (void)onToggleKeyboard { [_input toggleKeyboard]; }
- (void)onEsc  { [_input pressSpecial:WineKeyEsc]; }
- (void)onTab  { [_input pressSpecial:WineKeyTab]; }
- (void)onCtrl { [_input pressSpecial:WineKeyCtrl]; [self mark:_ctrlButton on:[_input ctrlHeld]]; }
- (void)onAlt  { [_input pressSpecial:WineKeyAlt];  [self mark:_altButton on:[_input altHeld]]; }
- (void)onResetZoom { [_input resetZoom]; }

- (void)mark:(UIButton *)b on:(BOOL)on {
  b.tintColor = on ? UIColor.systemYellowColor : UIColor.whiteColor;
}

- (void)onShowTasks {
  UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[WineTaskListVC new]];
  nav.modalPresentationStyle = UIModalPresentationPageSheet;
  [self presentViewController:nav animated:YES completion:nil];
}

- (void)onHideInput {
  _inputBarChrome.hidden = YES;
  _showBar.hidden = NO;
}

- (void)onShowInput {
  _showBar.hidden = YES;
  _inputBarChrome.hidden = NO;
}

/* --- Wine ---------------------------------------------------------------- */

- (void)launchWine {
  KitsuneDiagPolicy policy = KitsuneDiagPolicyFor(KitsuneDiagLevelFromEnv());
  dispatch_async(dispatch_get_main_queue(), ^{ self->_runBtn.hidden = YES; });
  [self say:@"handing the process to Wine; the app exits when the program finishes"];
  if (policy.shader_cache_census) [self say:ShaderCacheCensus()];
  (void)WineLogPathC();
  KitsuneLog(KitsuneMemLine(@"pre-launch"));

  BOOL showPulse = KitsuneDiagLevelFromEnv() != KitsuneDiagOff;
  KitsuneHeartbeatStart(policy, WineLogPathC(), ^(NSString *text, BOOL growing) {
    if (!showPulse) return;
    self->_pulse.text = text;
    self->_pulse.textColor = growing ? UIColor.systemGreenColor : UIColor.secondaryLabelColor;
  });

  char err[512] = {0};
  int ok = WineBootRun(_argv, ^(NSString *l) { [self say:[@"  " stringByAppendingString:l]]; }, err, sizeof(err));
  KitsuneHeartbeatStop();
  int status = 0;
  if (ok && WineBootExited(&status) && _sessionBottle) {
    /* The session host outlives every program, so Wine itself has stopped. */
    dispatch_async(dispatch_get_main_queue(), ^{ [self->_sessionTimer invalidate]; });
    _wineStopped = YES;
    [self setPhase:WineBootPhaseFailed message:[NSString stringWithFormat:NSLocalizedString(@"Wine stopped (code %d). Opening a program restarts Kitsune.", nil), status]];
    KitsuneLog([NSString stringWithFormat:@"SESSION-EXIT %d", status]);
    return;
  }
  if (ok && WineBootExited(&status)) {
    _wineStopped = YES;
    [self setPhase:WineBootPhaseFailed message:[NSString stringWithFormat:NSLocalizedString(@"The program exited (code %d). Opening another restarts Kitsune.", nil), status]];
    [self say:[NSString stringWithFormat:@"program exited with code %d; opening another restarts the app", status]];
    KitsuneLog([NSString stringWithFormat:@"PROGRAM-EXIT %d", status]);
    [self showProgramOutput];
    return;
  }
  _wineStopped = YES;
  [self setPhase:WineBootPhaseFailed message:[NSString stringWithFormat:NSLocalizedString(@"Wine didn't start: %s", nil), err[0] ? err : NSLocalizedString(@"unknown error", nil).UTF8String]];
  [self say:[NSString stringWithFormat:@"boot failed: %s", err[0] ? err : "(no reason reported)"]];
  KitsuneLog([NSString stringWithFormat:@"BOOT-FAILED %s", err]);
}

@end

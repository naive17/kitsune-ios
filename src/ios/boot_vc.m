#import "boot_vc_private.h"

#import <GameController/GameController.h>

#include "diagnostics.h"
#include "log_tail.h"
#include "wine_surface.h"

#include <dlfcn.h>

static NSString *ShaderCacheCensus(void) {
  NSString *dir = WineShaderCacheRoot();
  NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil];
  unsigned long long total = 0;
  for (NSString *n in names)
    total += [[NSFileManager.defaultManager attributesOfItemAtPath:[dir stringByAppendingPathComponent:n] error:nil] fileSize];
  return [NSString stringWithFormat:@"shader cache: %lu files, %llu KB", (unsigned long)names.count, total >> 10];
}

@implementation WineBootVC

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

- (void)onRun {
  _runBtn.hidden = YES;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [self launchWine]; });
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  [self arrangeBar];
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

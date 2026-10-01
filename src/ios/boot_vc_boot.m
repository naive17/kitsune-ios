#import "boot_vc_private.h"

#include "bottles.h"
#include "diagnostics.h"
#include "game_controller.h"
#include "jit_alloc.h"
#include "jit_arena.h"
#include "launch_request.h"
#include "log_tail.h"
#include "mach_excmon.h"
#include "pe_info.h"
#include "runtime_tree.h"

#include <sys/stat.h>

/* Steam's client DLLs hold absolute self-references and must stay in the
 * executable arena with FEX's translations; 1024 MB is the measured need. */
#ifndef ARENA_MB
#define ARENA_MB 1024
#endif
#define WINE_SHARED_DATA_ADDR 0x120000000ull

static void ArenaPrepared(double done, void *ctx) {
  [(__bridge WineBootVC *)ctx arenaPrepared:done];
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

@implementation WineBootVC (Boot)

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

@end

/*
 * Diagnostics policy: what the app pays for on every launch.
 *
 * One level, read once, applied everywhere. The heartbeat, thread dumps, guest
 * sampler, Mach exception monitor, Metal debug and XInput trace each cost CPU
 * or I/O on a phone already at its memory and thermal limits, so each is gated
 * by level:
 *
 *   Off    play mode. hb.log keeps a 30 s liveness tick with memory headroom
 *          (that is what tells a jetsam kill from a hang after the fact) and
 *          the wine log keeps ERR lines. Nothing samples the guest, dumps
 *          threads or copies the log.
 *   Basic  a 10 s heartbeat with the guest sampler and the previous-run log
 *          preview, still file-only. For "it died, why" without a Mac.
 *   Full   5 s ticks with 100 ms chunks for
 *          the first five, thread + VM dumps at IOSWINE_THREAD_DUMP, log
 *          snapshots, the Mach exception monitor, Metal debug and the XInput
 *          trace.
 *
 * Persisted as an integer in NSUserDefaults ("ioswine.diag.level"). main()
 * copies the choice into the environment before anything reads it, because
 * wine_boot's configure_environment() and the driver both consult getenv, not
 * NSUserDefaults.
 */
#ifndef IOSWINE_DIAGNOSTICS_H
#define IOSWINE_DIAGNOSTICS_H

#import <Foundation/Foundation.h>
#include <stdlib.h>
#include <string.h>

typedef NS_ENUM(NSInteger, IOSWineDiagLevel) {
  IOSWineDiagOff = 0,
  IOSWineDiagBasic = 1,
  IOSWineDiagFull = 2,
};

typedef struct {
  unsigned heartbeat_seconds;   /* steady-state tick, after the first few */
  BOOL fine_first_ticks;        /* 100 ms chunks for the first five ticks */
  BOOL guest_sampler;           /* thread_get_state + dladdr on the guest */
  BOOL thread_dumps;            /* WineBootDumpThreads/DumpVM (needs IOSWINE_THREAD_DUMP too) */
  BOOL log_snapshot;            /* copy wine-stderr.log to .snap on each dump */
  BOOL mach_exc_monitor;        /* Mach exception ports logged into hb.log */
  BOOL previous_log_preview;    /* read the last run's log tail at startup */
  BOOL boot_probes;             /* VM dump after the arena, fixed-map probe */
  BOOL shader_cache_census;     /* stat the DXMT cache directory at launch */
  const char *winedebug_steam;  /* WINEDEBUG for the Steam bottle */
  const char *winedebug_other;  /* WINEDEBUG for everything else */
} IOSWineDiagPolicy;

static inline IOSWineDiagPolicy IOSWineDiagPolicyFor(IOSWineDiagLevel level) {
  IOSWineDiagPolicy p;
  memset(&p, 0, sizeof(p));
  switch (level) {
  case IOSWineDiagFull:
    p.heartbeat_seconds = 5;
    p.fine_first_ticks = YES;
    p.guest_sampler = YES;
    p.thread_dumps = YES;
    p.log_snapshot = YES;
    p.mach_exc_monitor = YES;
    p.previous_log_preview = YES;
    p.boot_probes = YES;
    p.shader_cache_census = YES;
    /* Steam's repeated OutputDebugString assertions make trace+seh grow into
     * hundreds of MB, so the Steam bottle never gets +seh. */
    p.winedebug_steam = "-all,err+all,trace+loaddll,trace+process,warn+crypt,fixme+crypt";
    p.winedebug_other = "-all,err+all,trace+loaddll,trace+process,trace+seh";
    break;
  case IOSWineDiagBasic:
    p.heartbeat_seconds = 10;
    p.guest_sampler = YES;
    p.previous_log_preview = YES;
    p.shader_cache_census = YES;
    p.winedebug_steam = "-all,err+all,trace+loaddll";
    p.winedebug_other = "-all,err+all,trace+loaddll";
    break;
  default:
    p.heartbeat_seconds = 30;
    /* ERR stays: it is how a real failure announces itself and it is rare in
     * a healthy run. Everything chatty (a line per module load, per process,
     * per fixme) goes. */
    p.winedebug_steam = "-all,err+all";
    p.winedebug_other = "-all,err+all";
    break;
  }
  return p;
}

/* The environment a launch carries at each level: a Steam launch request has
 * it, and configure_environment() adds it for any other launch. These are the
 * toggles the Wine side and the driver read with getenv; a play launch must not
 * carry them, which is why they are not baked into the presets. */
static inline NSDictionary<NSString *, NSString *> *IOSWineDiagLaunchEnv(IOSWineDiagLevel level) {
  switch (level) {
  case IOSWineDiagFull:
    return @{
      @"IOSWINE_THREAD_DUMP": @"5",      /* all host threads + VM map to hb.log every 5 s */
      @"IOSWINE_TRACE_BIGALLOC": @"256", /* every >= 256 MB reservation, with a stack */
      @"IOSWINE_XINPUT_TRACE": @"1",     /* one line per controller state change */
      @"WINEIOS_METAL_DEBUG": @"1",      /* layer lifecycle and frame markers to stderr */
      @"WINE_IOS_VA_CENSUS": @"1",       /* address space left after startup */
    };
  case IOSWineDiagBasic:
    return @{ @"IOSWINE_TRACE_BIGALLOC": @"1024" };
  default:
    return @{};
  }
}

/* What the process was started with: IOSWINE_DIAG_LEVEL, else Off. */
static inline IOSWineDiagLevel IOSWineDiagLevelFromEnv(void) {
  const char *level = getenv("IOSWINE_DIAG_LEVEL");
  if (!level || !*level) return IOSWineDiagOff;
  long v = strtol(level, NULL, 10);
  if (v <= IOSWineDiagOff) return IOSWineDiagOff;
  if (v >= IOSWineDiagFull) return IOSWineDiagFull;
  return (IOSWineDiagLevel)v;
}

/* The persisted choice; Off until one is made. */
static inline IOSWineDiagLevel IOSWineDiagLevelStored(NSUserDefaults *ud) {
  NSInteger v = [ud integerForKey:@"ioswine.diag.level"];
  if (v < IOSWineDiagOff) return IOSWineDiagOff;
  if (v > IOSWineDiagFull) return IOSWineDiagFull;
  return (IOSWineDiagLevel)v;
}

static inline void IOSWineDiagStore(NSUserDefaults *ud, IOSWineDiagLevel level) {
  [ud setInteger:level forKey:@"ioswine.diag.level"];
}

/* Copy the stored choice into the environment. Must run before wine_boot's
 * configure_environment() and before the driver loads. */
static inline IOSWineDiagLevel IOSWineDiagApplyToEnvironment(NSUserDefaults *ud) {
  IOSWineDiagLevel level = IOSWineDiagLevelStored(ud);
  char buf[4];
  snprintf(buf, sizeof(buf), "%d", (int)level);
  setenv("IOSWINE_DIAG_LEVEL", buf, 1);
  return level;
}

#endif

/* Runtime side (diagnostics.m). */
#ifdef __OBJC__
/* Open hb.log, install the fatal-signal and atexit handlers. Call once, early. */
void IOSWineDiagInit(void);
/* Append a line to hb.log and NSLog. */
void IOSWineLog(NSString *line);
/* hb.log only; for C callers such as the thread dumper. */
void IOSWineLogC(const char *line);
int IOSWineHeartbeatFd(void);
unsigned long long IOSWinePhysFootprintMB(void);
NSString *IOSWineMemLine(NSString *where);
/* Heartbeat thread for a Wine session; `status` is called on the main thread
 * with a short liveness string. `wineLogPath` is the file whose growth it
 * reports. */
void IOSWineHeartbeatStart(IOSWineDiagPolicy policy, const char *wineLogPath, void (^status)(NSString *text, BOOL growing));
void IOSWineHeartbeatStop(void);
#endif

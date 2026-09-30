#import <UIKit/UIKit.h>
#import "diagnostics.h"
#import "wine_boot.h"
#import "wine_surface.h"

#include <execinfo.h>
#include <os/proc.h>
#include <mach/mach.h>
#include <pthread.h>
#include <signal.h>
#include <sys/stat.h>

static int g_hb_fd = -1;
static char g_last_stage[160];
static volatile int g_hb_stop;
static char g_wine_log[PATH_MAX];

static NSString *HBLogPath(void) {
  return [KitsunePersistentDocuments() stringByAppendingPathComponent:@"hb.log"];
}

int KitsuneHeartbeatFd(void) { return g_hb_fd; }

unsigned long long KitsunePhysFootprintMB(void) {
  task_vm_info_data_t info;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
  return (unsigned long long)(info.phys_footprint >> 20);
}

NSString *KitsuneMemLine(NSString *where) {
  return [NSString stringWithFormat:@"MEM %@ avail=%lluMB footprint=%lluMB", where,
          (unsigned long long)(os_proc_available_memory() >> 20), KitsunePhysFootprintMB()];
}

/* hb.log is written with write(2) on an fd opened before Wine starts, so no
 * later redirection or lock can lose it. */
static void hb_write(const char *s) {
  char line[512];
  int n;
  if (g_hb_fd < 0 || !s) return;
  n = snprintf(line, sizeof line, "%.3f %s\n", CFAbsoluteTimeGetCurrent(), s);
  if (n > 0) { ssize_t w = write(g_hb_fd, line, (size_t)(n < (int)sizeof line ? n : (int)sizeof line - 1)); (void)w; }
}

void KitsuneLogC(const char *line) { hb_write(line); }

void KitsuneLog(NSString *s) {
  NSLog(@"[kitsune] %@", s);
  strlcpy(g_last_stage, s.UTF8String ?: "?", sizeof(g_last_stage));
  hb_write(s.UTF8String);
}

/* --- fatal paths --------------------------------------------------------- */

static void write_backtrace(const char *what) {
  void *frames[32];
  int n = backtrace(frames, 32);
  char **syms = backtrace_symbols(frames, n);
  char buf[256];
  int k;
  snprintf(buf, sizeof buf, "%s backtrace (%d frames)", what, n);
  hb_write(buf);
  for (k = 0; k < n && syms; k++) {
    snprintf(buf, sizeof buf, "  #%02d %s", k, syms[k]);
    hb_write(buf);
  }
}

static void fatal_signal_handler(int sig) {
  char buf[256];
  snprintf(buf, sizeof buf, "SIGNAL %d after: %s", sig, g_last_stage);
  hb_write(buf);
  write_backtrace("SIGNAL");
  _exit(128 + sig);
}

static void atexit_handler(void) {
  char buf[256];
  write_backtrace("EXIT");
  snprintf(buf, sizeof buf, "EXIT after: %s", g_last_stage);
  hb_write(buf);
}

void KitsuneDiagInit(void) {
  static const int sigs[] = { SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE };
  if (g_hb_fd >= 0) return;
  g_hb_fd = open(HBLogPath().fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0644);
  for (unsigned i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) signal(sigs[i], fatal_signal_handler);
  atexit(atexit_handler);
}

/* --- heartbeat ----------------------------------------------------------- */

void KitsuneHeartbeatStart(KitsuneDiagPolicy policy, const char *wineLogPath, void (^status)(NSString *, BOOL)) {
  strlcpy(g_wine_log, wineLogPath, sizeof(g_wine_log));
  g_hb_stop = 0;
  CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
  NSThread *thread = [[NSThread alloc] initWithBlock:^{
    static const unsigned schedule[] = { 1, 1, 2, 2, 3 };
    unsigned n = 0;
    long prev_size = 0;
    KitsuneLog(@"HB entered");
    WineBootLogImageBases(KitsuneLogC);
    while (!g_hb_stop) {
      unsigned want = n < sizeof(schedule) / sizeof(schedule[0]) ? schedule[n] : policy.heartbeat_seconds;
      if (policy.fine_first_ticks && n < 5) {
        for (unsigned chunk = 0; chunk < want * 10; chunk++) {
          struct timespec ts = { 0, 100 * 1000 * 1000 };
          int rc = nanosleep(&ts, NULL), e = errno;
          hb_write([NSString stringWithFormat:@"HB tick-%u chunk %u rc=%d errno=%d avail=%lluMB footprint=%lluMB",
                    n + 1, chunk, rc, rc ? e : 0, (unsigned long long)(os_proc_available_memory() >> 20),
                    KitsunePhysFootprintMB()].UTF8String);
        }
      } else {
        sleep(want);
      }
      if (g_hb_stop) break;
      /* An app started in landscape gets no rotation event; re-fit once the
       * driver is up so the guest desktop follows the interface. */
      if (n >= 8 && n <= 40 && wine_surface_host_screen_is_portrait()) dispatch_async(dispatch_get_main_queue(), ^{
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
          if ([sc isKindOfClass:UIWindowScene.class] &&
              UIInterfaceOrientationIsLandscape(((UIWindowScene *)sc).interfaceOrientation)) {
            wine_surface_host_rotate();
            break;
          }
        }
      });
      struct stat st;
      long sz = stat(g_wine_log, &st) == 0 ? (long)st.st_size : -1;
      unsigned tick = ++n;
      extern int wine_input_overlay_alive, wine_input_gestures, wine_input_sent, wine_input_unmapped,
                 wine_input_resolved, wine_input_last_x, wine_input_last_y;
      extern const char *wine_input_status;
      KitsuneLog([NSString stringWithFormat:
          @"HB %u log=%ld avail=%lluMB footprint=%lluMB in{ov=%d drv=%#x g=%d sent=%d unmapped=%d last=%d,%d} srv{%s}",
          tick, sz, (unsigned long long)(os_proc_available_memory() >> 20), KitsunePhysFootprintMB(),
          wine_input_overlay_alive, wine_input_resolved, wine_input_gestures, wine_input_sent, wine_input_unmapped,
          wine_input_last_x, wine_input_last_y, wine_input_status ? wine_input_status : "-"]);
      if (status) {
        static const char spin[] = "|/-\\";
        long delta = (prev_size > 0 && sz >= prev_size) ? sz - prev_size : 0;
        unsigned up = (unsigned)(CFAbsoluteTimeGetCurrent() - start);
        NSString *text = [NSString stringWithFormat:@" %c %um%02us  log+%ldB  %lluMB ",
                          spin[tick & 3], up / 60, up % 60, delta, KitsunePhysFootprintMB()];
        dispatch_async(dispatch_get_main_queue(), ^{ status(text, delta > 0); });
        prev_size = sz;
      }
      if (policy.thread_dumps) {
        static CFAbsoluteTime last_dump;
        const char *e = getenv("KITSUNE_THREAD_DUMP");
        int every = e ? atoi(e) : 0;
        if (e && every <= 0) every = 60;
        if (every > 0 && CFAbsoluteTimeGetCurrent() - last_dump >= every) {
          char tag[32];
          last_dump = CFAbsoluteTimeGetCurrent();
          snprintf(tag, sizeof tag, "tick-%u", tick);
          WineBootDumpThreads(tag, KitsuneLogC);
          WineBootDumpVM(tag, KitsuneLogC);
          if (policy.log_snapshot) {
            char snap[PATH_MAX];
            snprintf(snap, sizeof snap, "%s.snap", g_wine_log);
            WineBootSnapshotLog(g_wine_log, snap);
          }
        }
      }
      /* The sampler takes dyld's lock; it runs on a side thread so a guest
       * parked in dlopen cannot stall the heartbeat. */
      if (policy.guest_sampler) {
        static volatile int busy;
        static unsigned since;
        if (!busy) {
          busy = 1;
          since = tick;
          dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            char guest[256];
            WineBootSampleGuest(guest, sizeof guest);
            KitsuneLog([NSString stringWithFormat:@"HB %u guest %s", tick, guest]);
            busy = 0;
          });
        } else {
          KitsuneLog([NSString stringWithFormat:@"HB %u guest sampler busy since tick %u", tick, since]);
        }
      }
    }
  }];
  thread.stackSize = 4 * 1024 * 1024;
  [thread start];
  KitsuneLog(@"HB thread requested");
}

void KitsuneHeartbeatStop(void) { g_hb_stop = 1; }

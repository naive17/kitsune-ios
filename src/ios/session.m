#import "session.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#include "wine_command.h"

/* The sizes the driver hands to CreateProcessW (struct wineios_drain_params). */
#define CMDLINE_MAX 4096
#define CWD_MAX 1024

struct launch { char *cmdline, *cwd; };

static pthread_mutex_t queue_lock = PTHREAD_MUTEX_INITIALIZER;
static struct launch queue[16];
static unsigned queue_head, queue_count;

extern int wineserver_inproc_user_processes(void);

NSString *KitsuneSessionHostPath(void) {
  return [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"lib/wine/aarch64-windows/kitsune-session.exe"];
}

BOOL KitsuneSessionQueue(NSArray<NSString *> *argv, NSString *cwd) {
  NSString *cmdline = KitsuneWindowsCommandLine(argv);
  NSString *dir = cwd.length ? KitsuneWindowsPath(cwd) : @"";
  if (!argv.count || cmdline.length >= CMDLINE_MAX || dir.length >= CWD_MAX) return NO;
  BOOL queued = NO;
  pthread_mutex_lock(&queue_lock);
  if (queue_count < sizeof(queue) / sizeof(queue[0])) {
    struct launch *slot = &queue[(queue_head + queue_count) % (sizeof(queue) / sizeof(queue[0]))];
    slot->cmdline = strdup(cmdline.UTF8String);
    slot->cwd = strdup(dir.UTF8String);
    queue_count++;
    queued = YES;
  }
  pthread_mutex_unlock(&queue_lock);
  return queued;
}

/* Called by the display driver on the session host's drain thread, a Wine
 * thread: plain C only. 1 with a program, 0 when the queue is empty. */
__attribute__((visibility("default")))
int wine_surface_host_take_launch(char *cmdline, size_t cmdline_size, char *cwd, size_t cwd_size) {
  struct launch next = { NULL, NULL };
  pthread_mutex_lock(&queue_lock);
  if (queue_count) {
    next = queue[queue_head];
    queue_head = (queue_head + 1) % (sizeof(queue) / sizeof(queue[0]));
    queue_count--;
  }
  pthread_mutex_unlock(&queue_lock);
  if (!next.cmdline) return 0;
  BOOL fits = strlcpy(cmdline, next.cmdline, cmdline_size) < cmdline_size && strlcpy(cwd, next.cwd, cwd_size) < cwd_size;
  free(next.cmdline);
  free(next.cwd);
  return fits ? 1 : -1;
}

int KitsuneSessionPrograms(void) {
  int processes = wineserver_inproc_user_processes();
  return processes > 1 ? processes - 1 : 0;
}

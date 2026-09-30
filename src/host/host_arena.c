/*
 * The blessed arena, faked on macOS so the same Wine code can be tested here.
 *
 * WHY THIS EXISTS. Every device iteration costs ~6 minutes: build, install,
 * launch with JIT, pull the logs. Most of what that was catching was not iOS
 * behaviour at all, it was ordinary bugs of mine -- a bitmap size that was not
 * page-rounded, a variable used before its declaration, section alignment
 * assumed to be 4 KB when iOS pages are 16 KB, a warning reading the wrong
 * protection bits. All of those reproduce on this Mac.
 *
 * WHY NOT THE SIMULATOR. The simulator is a normal macOS process: no AMFI, no
 * debugger handshake, nothing to bless. Measured on this host:
 *
 *     mmap RWX                        -> fails      (same as iOS)
 *     mmap RW; mprotect RX; execute   -> WORKS      (iOS refuses this)
 *
 * So plain unpatched Wine would simply succeed there. The simulator does not
 * reproduce the constraint that defines this port; it manufactures false
 * passes, which this project has already been burned by three times.
 *
 * WHAT THIS DOES INSTEAD. It builds a real dual mapping with the same shape as
 * the device -- an RX region plus an RW alias of the same physical pages, via
 * vm_remap -- and exports the same symbols, so dlls/ntdll/unix/virtual.c runs
 * its arena path unmodified. The host page size is 16 KB here too, which is
 * what makes the alignment bugs reproduce.
 *
 * WHAT IT CANNOT TELL YOU, and must still be answered on hardware:
 *
 *   - whether mprotect( PROT_EXEC ) is refused          (here it is allowed)
 *   - whether mmap MAP_FIXED over blessed pages EACCESes (here it succeeds)
 *   - whether protection changes are one-way             (here they are not)
 *   - anything about real JIT, CS_DEBUGGED, or StikDebug
 *
 * Those are known and encoded now, which is why the remaining surface is small.
 * To keep the host from being LAXER than the device where it matters, the
 * checks below make the violations that iOS punishes fatal here instead of
 * silent -- see host_arena_verify().
 */

#include "jit_arena.h"

#include <errno.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

/*
 * 640 MB, not 512: the arena has to CONTAIN 0x140000000 for the fixed-base exe
 * window below, and from the pinned base 0x120010000 that needs 0x1fff0000 +
 * the window itself. 640 matches ARENA_PIN_MIN_MB on device.
 */
#define ARENA_DEFAULT (640u << 20)

/*
 * The fixed-base exe window, mirroring src/ios/jit_arena.c.
 *
 * An x64 exe linked without relocations (/FIXED, IMAGE_FILE_RELOCS_STRIPPED)
 * can only run at its preferred base, and MSVC's default for x64 exes is
 * 0x140000000 -- inside the arena. Dark Souls Remastered is one. Relocated
 * anywhere else it does not merely fail to start: the loader maps it fine and
 * then alloc_tls_slot writes the TLS index through the image's UNRELOCATED
 * AddressOfIndex, which is a wild store to an unmapped page --
 *
 *   alloc_tls_slot module 0x10913C000 ... index 0x141D054A4 ... -> slot 0
 *   ios-fault #1: sig=11 addr=0x141d054a4 ... page unmapped
 *
 * -- i.e. it dies before reaching a single line of its own code. Without this
 * window the harness cannot run the one game we most need to iterate on, which
 * is exactly the round trip it exists to remove.
 */
#define EXE_WINDOW_BASE 0x140000000ULL

static char *g_exec, *g_write;
static size_t g_size, g_used;
static ptrdiff_t g_delta;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_ready;

/*
 * Keep-out, same as the device.
 *
 * Stubbing this out was a mistake: the harness immediately reproduced the exact
 * device failure it was meant to model --
 *     err:virtual:virtual_alloc_first_teb failed to map the shared user data:
 *     c0000018
 * -- because the arena landed across 0x120000000, where Wine pins
 * KUSER_SHARED_DATA. Reserving it first is what the app does, so the harness
 * has to do it too or it tests a configuration we do not ship.
 */
static void *g_keepout;
static size_t g_keepout_len;

int ios_jit_arena_reserve(void *addr, size_t len, char *err, size_t errlen) {
  void *got = mmap(addr, len, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
  if (got == MAP_FAILED) {
    snprintf(err, errlen, "reserve %p+%zu: %s", addr, len, strerror(errno));
    return 0;
  }
  g_keepout = got;
  g_keepout_len = len;
  return 1;
}

void ios_jit_arena_release_reserved(void) {
  if (g_keepout) munmap(g_keepout, g_keepout_len);
  g_keepout = NULL;
  g_keepout_len = 0;
}

static size_t g_win_lo = (size_t)-1, g_win_hi;

/* KITSUNE_EXE_WINDOW_MB sizes it (default 64; 0 disables), same knob as iOS.
 * Silently stays off if the arena did not land somewhere that contains the
 * window -- callers must cope with no window, because on device the pin is a
 * lottery and can lose. */
static void arena_setup_exe_window(void) {
  const char *e = getenv("KITSUNE_EXE_WINDOW_MB");
  size_t mb = e ? (size_t)atol(e) : 64;
  uintptr_t lo = (uintptr_t)g_exec, hi = lo + g_size;

  if (!mb || EXE_WINDOW_BASE < lo || EXE_WINDOW_BASE + (mb << 20) > hi) return;
  g_win_lo = (size_t)(EXE_WINDOW_BASE - lo);
  g_win_hi = g_win_lo + (mb << 20);
}

void ios_jit_arena_exe_window(void **base, size_t *size) {
  *base = g_win_lo == (size_t)-1 ? NULL : g_exec + g_win_lo;
  *size = g_win_lo == (size_t)-1 ? 0 : g_win_hi - g_win_lo;
}

int ios_jit_arena_init(size_t size, char *err, size_t errlen) {
  pthread_mutex_lock(&g_lock);
  if (g_ready) { pthread_mutex_unlock(&g_lock); return 1; }
  if (!size) size = ARENA_DEFAULT;

  size_t page = (size_t)getpagesize();
  size = (size + page - 1) & ~(page - 1);

  /*
   * Stand in for the debugger's allocation: get pages, then make them RX and
   * never writable again through this mapping. From here on the only way to
   * write is the alias, exactly as on device.
   */
  /*
   * Ask for the device's pinned base rather than letting the kernel choose.
   * Not MAP_FIXED: that would clobber whatever is there. macOS treats a plain
   * hint as advisory and places us elsewhere if it is busy, which only costs
   * us the exe window (arena_setup_exe_window then declines) -- the same
   * graceful loss the device takes when the pin lottery fails.
   */
  void *p = mmap((void *)0x120010000ull, size, PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | MAP_ANON, -1, 0);
  if (p == MAP_FAILED)
    p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
  if (p == MAP_FAILED) {
    snprintf(err, errlen, "mmap(%zu): %s", size, strerror(errno));
    pthread_mutex_unlock(&g_lock);
    return 0;
  }
  if (mprotect(p, size, PROT_READ | PROT_EXEC)) {
    snprintf(err, errlen, "mprotect(RX): %s", strerror(errno));
    munmap(p, size);
    pthread_mutex_unlock(&g_lock);
    return 0;
  }

  mach_port_t task = mach_task_self();
  vm_address_t alias = 0;
  vm_prot_t cur = VM_PROT_NONE, max = VM_PROT_NONE;
  kern_return_t kr = vm_remap(task, &alias, (vm_size_t)size, 0, VM_FLAGS_ANYWHERE,
                              task, (vm_address_t)(uintptr_t)p, FALSE, &cur, &max,
                              VM_INHERIT_NONE);
  if (kr != KERN_SUCCESS) {
    snprintf(err, errlen, "vm_remap: %d", kr);
    munmap(p, size);
    pthread_mutex_unlock(&g_lock);
    return 0;
  }
  if (vm_protect(task, alias, (vm_size_t)size, FALSE, VM_PROT_READ | VM_PROT_WRITE)
      != KERN_SUCCESS) {
    snprintf(err, errlen, "vm_protect(alias RW) (max=0x%x)", max);
    munmap(p, size);
    pthread_mutex_unlock(&g_lock);
    return 0;
  }

  g_exec  = p;
  g_write = (char *)(uintptr_t)alias;
  g_delta = g_write - g_exec;
  g_size  = size;
  g_used  = 0;
  g_ready = 1;
  arena_setup_exe_window();
  pthread_mutex_unlock(&g_lock);
  return 1;
}

int ios_jit_arena_alloc(size_t size, size_t align, void **exec, void **write) {
  if (!g_ready || !size) return 0;
  if (align < 16) align = 16;

  pthread_mutex_lock(&g_lock);
  size_t off = (g_used + align - 1) & ~(align - 1);
  /* Step over the fixed-base exe window: it belongs to whichever
   * relocs-stripped exe claims it, and handing it to an ordinary image view
   * would make that exe unloadable. */
  if (off < g_win_hi && off + size > g_win_lo)
    off = (g_win_hi + align - 1) & ~(align - 1);
  if (off + size > g_size) { pthread_mutex_unlock(&g_lock); return 0; }
  g_used = off + size;
  pthread_mutex_unlock(&g_lock);

  *exec  = g_exec  + off;
  *write = g_write + off;
  return 1;
}

/* Wine returns image views here. As on the device, a freed range is never
 * handed out again: its bits in the EC code bitmap are shared by every process
 * in the task, and reuse would race the x64 processes reading them. The pages
 * stay mapped and RX-blessed. */
void ios_jit_arena_free(void *exec, size_t size) {
  (void)exec;
  (void)size;
}

void ios_jit_arena_bounds(void **exec_lo, size_t *size, ptrdiff_t *delta) {
  if (exec_lo) *exec_lo = g_ready ? g_exec : NULL;
  if (size)    *size    = g_ready ? g_size : 0;
  if (delta)   *delta   = g_ready ? g_delta : 0;
}

void ios_jit_arena_publish(void *exec_addr, size_t len) {
  sys_icache_invalidate(exec_addr, len);
}

/*
 * Catch, on the host, the mistakes the device would punish.
 *
 * macOS permits things iOS does not, so a clean run here proves less than it
 * appears to. The one violation worth checking cheaply is a page that ended up
 * both writable and executable: on iOS that combination cannot exist, so if it
 * appears here the logic is wrong even though nothing failed.
 *
 * Call after Wine has finished loading images.
 */
int host_arena_verify(void) {
  mach_port_t task = mach_task_self();
  char *p = g_exec;
  int bad = 0;

  if (!g_ready) return 0;

  while (p < g_exec + g_size) {
    vm_address_t addr = (vm_address_t)(uintptr_t)p;
    vm_size_t sz = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj = MACH_PORT_NULL;

    if (vm_region_64(task, &addr, &sz, VM_REGION_BASIC_INFO_64,
                     (vm_region_info_t)&info, &cnt, &obj) != KERN_SUCCESS) break;
    if (addr >= (vm_address_t)(uintptr_t)(g_exec + g_size)) break;

    if ((info.protection & VM_PROT_WRITE) && (info.protection & VM_PROT_EXECUTE)) {
      fprintf(stderr,
              "harness: FAIL %p+%llx is W+X (prot=0x%x). iOS cannot produce this "
              "page; something made an arena page writable without giving up "
              "exec.\n", (void *)(uintptr_t)addr, (unsigned long long)sz,
              info.protection);
      bad++;
    }
    p = (char *)(uintptr_t)(addr + sz);
  }
  return bad;
}

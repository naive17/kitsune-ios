
#include "jit_arena.h"
#include <stdlib.h>

#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <sys/mman.h>
#include <unistd.h>

#include "jit_alloc.h"

#define ARENA_DEFAULT (256u << 20)   /* measured OK on device; FEX wants <=128 MB */

static jit_region g_arena;
static size_t g_used;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_ready;

/* The low window the arena must live in: above Wine's KUSER_SHARED_DATA page
 * (WINE_SHARED_DATA_ADDR + 64KB) and below iOS's own immovable r--/r-- band at
 * 0x180000000. 1.5GB total, of which the arena wants 1GB. */
#define PIN_WINDOW_HI 0x180000000ULL
#define ARENA_PIN_MIN_MB 640

static void arena_setup_exe_window(void);
static void arena_setup_code_region(void);
static size_t arena_code_take(size_t size);
static int arena_code_give_back(size_t off, size_t size);
static size_t arena_jit_take(size_t size, size_t align);

static void *g_keepout;
static size_t g_keepout_len;

int ios_jit_arena_reserve(void *addr, size_t len, char *err, size_t errlen) {
  void *got = mmap(addr, len, PROT_NONE,
                   MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
  if (got == MAP_FAILED) {
    snprintf(err, errlen, "reserve %p+%zu: %s", addr, len, strerror(errno));
    return 0;
  }
  if (got != addr) {
    snprintf(err, errlen, "reserve landed at %p, wanted %p", got, addr);
    munmap(got, len);
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

static vm_address_t g_pin_addr;
static vm_size_t    g_pin_len;
static char         g_pin_note[1280];
static unsigned     g_ent_before, g_ent_small_before;

static void pin_describe_squatters(vm_address_t lo, vm_address_t hi,
                                   char *out, size_t outlen) {
  vm_address_t a = lo;
  size_t n = 0;
  int count = 0;
  while (a < hi && count < 6) {
    vm_size_t sz = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj = MACH_PORT_NULL;
    if (vm_region_64(mach_task_self(), &a, &sz, VM_REGION_BASIC_INFO_64,
                     (vm_region_info_t)&info, &cnt, &obj) != KERN_SUCCESS) break;
    if (a >= hi) break;
    n += (size_t)snprintf(out + n, outlen > n ? outlen - n : 0,
                          " [%#lx+%#lx %c%c%c]", (unsigned long)a, (unsigned long)sz,
                          (info.protection & VM_PROT_READ) ? 'r' : '-',
                          (info.protection & VM_PROT_WRITE) ? 'w' : '-',
                          (info.protection & VM_PROT_EXECUTE) ? 'x' : '-');
    a += sz;
    count++;
  }
}

/* First hole of at least len bytes in [lo, hi), or 0. */
static vm_address_t pin_find_hole(vm_address_t lo, vm_address_t hi, size_t len) {
  vm_address_t a = lo, prev_end = lo;
  for (;;) {
    vm_size_t sz = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj = MACH_PORT_NULL;
    if (vm_region_64(mach_task_self(), &a, &sz, VM_REGION_BASIC_INFO_64,
                     (vm_region_info_t)&info, &cnt, &obj) != KERN_SUCCESS) a = hi;
    if (a > prev_end && a - prev_end >= len && prev_end + len <= hi) return prev_end;
    if (a >= hi) return 0;
    prev_end = a + sz;
    a = prev_end;
  }
}

static vm_address_t pin_find_largest_hole(vm_address_t lo, vm_address_t hi,
                                          size_t *out_len) {
  vm_address_t a = lo, prev_end = lo, best = 0;
  size_t best_len = 0;

  for (;;) {
    vm_size_t sz = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj = MACH_PORT_NULL;
    int end = 0;

    if (vm_region_64(mach_task_self(), &a, &sz, VM_REGION_BASIC_INFO_64,
                     (vm_region_info_t)&info, &cnt, &obj) != KERN_SUCCESS) { a = hi; end = 1; }
    if (a > hi) { a = hi; end = 1; }
    if (a > prev_end) {
      size_t hole = (size_t)(a - prev_end);
      if (hole > best_len) { best_len = hole; best = prev_end; }
    }
    if (end || a >= hi) break;
    prev_end = a + sz;
    if (prev_end >= hi) break;
    a = prev_end;
  }
  if (out_len) *out_len = best_len;
  return best;
}

int ios_jit_arena_pin_low(void *addr, size_t len) {
  vm_address_t want = (vm_address_t)(uintptr_t)addr, a = want;
  kern_return_t kr;
  char sq[512] = "";

  if (g_pin_addr) return 1;          /* the constructor already did it */
  kr = vm_allocate(mach_task_self(), &a, (vm_size_t)len, VM_FLAGS_FIXED);
  if (kr != KERN_SUCCESS) {
    /* Something (malloc regions, typically 4MB rw) already sits in the window
     * -- seen on 1 of 5 launches even from a constructor. Any hole below the
     * shared cache works just as well: the alias and Wine only need "low". */
    pin_describe_squatters(want, want + len, sq, sizeof sq);
    a = pin_find_hole(want, PIN_WINDOW_HI, len);
    if (a) kr = vm_allocate(mach_task_self(), &a, (vm_size_t)len, VM_FLAGS_FIXED);
  }
  if (kr != KERN_SUCCESS) {
    size_t hole = 0;
    vm_address_t h = pin_find_largest_hole(want, PIN_WINDOW_HI, &hole);

    hole &= ~(size_t)((64u << 20) - 1);        /* 64MB granularity */
    if (hole > len) hole = len;                /* never more than asked */
    if (h && hole >= ((size_t)ARENA_PIN_MIN_MB << 20)) {
      a = h;
      kr = vm_allocate(mach_task_self(), &a, (vm_size_t)hole, VM_FLAGS_FIXED);
      if (kr == KERN_SUCCESS) {
        /* Say it loudly: silently booting on 640MB when 1024 was asked for is
         * exactly what gets mis-diagnosed later as a leak. */
        fprintf( stderr, "ios: ARENA SHRUNK to %zu MB (asked %zu MB)\n",
                 (size_t)(hole >> 20), (size_t)(len >> 20) );
        len = hole;
      }
    }
  }
  if (kr == KERN_SUCCESS) {
    vm_protect(mach_task_self(), a, (vm_size_t)len, FALSE, VM_PROT_NONE);
    g_pin_addr = a;
    g_pin_len = (vm_size_t)len;
    snprintf(g_pin_note, sizeof g_pin_note, "ARENA-PIN held %#lx+%#zx%s%s",
             (unsigned long)a, len, a != want ? " (fallback hole; squatters:" : "",
             a != want ? sq : "");
    return 1;
  }
  snprintf(g_pin_note, sizeof g_pin_note,
           "ARENA-PIN FAILED %#lx+%#zx kr=%d squatters:%s",
           (unsigned long)want, len, kr, sq[0] ? sq : " (none visible)");
  return 0;
}

const char *ios_jit_arena_pin_note(void) { return g_pin_note; }
size_t ios_jit_arena_pinned_len(void) { return g_pin_addr ? (size_t)g_pin_len : 0; }

int ios_jit_arena_pin_low_adaptive(void *addr, size_t min_len, size_t max_len) {
  vm_address_t want = (vm_address_t)(uintptr_t)addr, a = want;
  vm_size_t sz = 0;
  vm_region_basic_info_data_64_t info;
  mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
  mach_port_t obj = MACH_PORT_NULL;
  size_t len = min_len;

  if (g_pin_addr) return 1;
  if (vm_region_64(mach_task_self(), &a, &sz, VM_REGION_BASIC_INFO_64,
                   (vm_region_info_t)&info, &cnt, &obj) == KERN_SUCCESS && a > want) {
    size_t hole = (size_t)(a - want);
    /* leave 32MB between the arena and whatever sits above it */
    hole = hole > (32u << 20) ? hole - (32u << 20) : 0;
    hole &= ~(size_t)((64u << 20) - 1);
    if (hole > max_len) hole = max_len;
    if (hole > len) len = hole;
  }
  return ios_jit_arena_pin_low(addr, len);
}


static unsigned arena_count_entries(unsigned *small_out) {
  vm_address_t a = 0;
  unsigned n = 0, small = 0;
  for (;;) {
    vm_size_t sz = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj = MACH_PORT_NULL;
    if (vm_region_64(mach_task_self(), &a, &sz, VM_REGION_BASIC_INFO_64,
                     (vm_region_info_t)&info, &cnt, &obj) != KERN_SUCCESS) break;
    if (!sz) break;
    n++;
    if (sz <= 0x10000) small++;
    a += sz;
    if (n >= 400000) break;
  }
  if (small_out) *small_out = small;
  return n;
}

/* The debugger prepares the arena this much at a time, so the app runs and
 * can report progress in between. */
#define ARENA_PREPARE_STEP (32u << 20)

static void (*g_progress)(double, void *);
static void *g_progress_ctx;

void ios_jit_arena_set_progress(void (*progress)(double done, void *ctx), void *ctx) {
  g_progress = progress;
  g_progress_ctx = ctx;
}

int ios_jit_arena_init(size_t size, char *err, size_t errlen) {
  vm_address_t pinned;

  pthread_mutex_lock(&g_lock);
  if (g_ready) { pthread_mutex_unlock(&g_lock); return 1; }

  if (!size) size = ARENA_DEFAULT;
  /* Learn whether the script answers while the pin is still held, so a launch
   * without it can be retried with the same window. */
  if (!jit_alloc_available(err, errlen)) {
    pthread_mutex_unlock(&g_lock);
    return -1;
  }
  {
    unsigned small_before = 0;
    g_ent_before = arena_count_entries(&small_before);
    g_ent_small_before = small_before;
  }
  /* Give the window back only now. Any allocation another thread makes before
   * the debugger's lands in it, and the arena then lands high. */
  pinned = g_pin_addr;
  if (g_pin_addr) {
    vm_deallocate(mach_task_self(), g_pin_addr, g_pin_len);
    g_pin_addr = 0;
  }
  if (!jit_region_alloc_stepwise(size, ARENA_PREPARE_STEP, g_progress, g_progress_ctx, &g_arena, err, errlen)) {
    pthread_mutex_unlock(&g_lock);
    return 0;
  }

  if ((uintptr_t)g_arena.exec >= 0x200000000ull) {
    snprintf(err, errlen,
             "arena landed HIGH at %p (pin lost); the RW alias does not work "
             "there and Wine would hang at boot -- relaunch",
             g_arena.exec);
    jit_region_free(&g_arena);
    memset(&g_arena, 0, sizeof g_arena);
    pthread_mutex_unlock(&g_lock);
    return 0;
  }
  {
    unsigned small_after = 0;
    unsigned ent_after = arena_count_entries(&small_after);
    size_t n = strlen(g_pin_note);

    snprintf(g_pin_note + n, sizeof g_pin_note - n,
             " -> arena %p %s | vm entries %u(small %u) -> %u(small %u), "
             "arena cost %d (%zu MB @ 128 entries/MB)",
             g_arena.exec,
             !pinned ? "(no pin)"
             : (vm_address_t)(uintptr_t)g_arena.exec == pinned ? "ON PIN"
             : "OFF PIN",
             g_ent_before, g_ent_small_before, ent_after, small_after,
             (int)ent_after - (int)g_ent_before, g_arena.size >> 20);
  }
  g_used = 0;
  arena_setup_exe_window();
  arena_setup_code_region();
  g_ready = 1;
  pthread_mutex_unlock(&g_lock);
  return 1;
}

size_t ios_jit_arena_size(void)      { return g_arena.size; }
int    ios_jit_arena_available(void) { return g_ready; }

#define EXE_WINDOW_BASE 0x140000000ULL
static size_t g_win_lo = (size_t)-1, g_win_hi;

static void arena_setup_exe_window(void) {
  const char *e = getenv("KITSUNE_EXE_WINDOW_MB");
  size_t mb = e ? (size_t)atol(e) : 64;
  uintptr_t lo = (uintptr_t)g_arena.exec, hi = lo + g_arena.size;

  if (!mb) { fprintf(stderr, "ios: exe window DISABLED by KITSUNE_EXE_WINDOW_MB=0\n"); return; }
  if (EXE_WINDOW_BASE < lo || EXE_WINDOW_BASE + (mb << 20) > hi) {
    fprintf(stderr,
            "ios: EXE WINDOW LOST -- arena %p-%p does not cover %#llx+%zuMB. "
            "A relocs-stripped exe (Dark Souls) will load at the wrong base and "
            "die in alloc_tls_slot. Relaunch to re-roll the arena pin.\n",
            (void *)lo, (void *)hi, (unsigned long long)EXE_WINDOW_BASE, mb);
    return;
  }
  g_win_lo = (size_t)(EXE_WINDOW_BASE - lo);
  g_win_hi = g_win_lo + (mb << 20);
  fprintf(stderr, "ios: exe window %#llx-%#llx (%zu MB) inside arena %p-%p\n",
          (unsigned long long)EXE_WINDOW_BASE,
          (unsigned long long)(EXE_WINDOW_BASE + (mb << 20)), mb, (void *)lo, (void *)hi);
}

void ios_jit_arena_exe_window(void **base, size_t *size) {
  *base = g_win_lo == (size_t)-1 ? NULL : (char *)g_arena.exec + g_win_lo;
  *size = g_win_lo == (size_t)-1 ? 0 : g_win_hi - g_win_lo;
}

#define ARENA_CODE_SLOT (64u << 20)
#define ARENA_CODE_SLOTS_MAX 16
static size_t g_code_lo, g_code_hi;         /* offsets into the arena */
static size_t g_code_max;                   /* ceiling on the region's size */
static unsigned g_code_slots;               /* how many slots exist */
static unsigned char g_code_used[ARENA_CODE_SLOTS_MAX];

static void arena_setup_code_region(void) {
  const char *e = getenv("KITSUNE_ARENA_CODE_MB");
  size_t mb = e ? (size_t)atol(e) : 512;   /* ceiling, not a reservation */

  g_code_max = mb << 20;
  if (g_code_max > (size_t)ARENA_CODE_SLOTS_MAX * ARENA_CODE_SLOT)
    g_code_max = (size_t)ARENA_CODE_SLOTS_MAX * ARENA_CODE_SLOT;
  g_code_hi = g_arena.size;
  g_code_lo = g_arena.size;
  g_code_slots = 0;
}

static void arena_drop_pages(size_t off, size_t size) {
  if (!g_arena.write || !size) return;
  madvise((char *)g_arena.write + off, size, MADV_FREE);
}

/* A contiguous run of free slots, or (size_t)-1. */
static size_t arena_code_take(size_t size) {
  unsigned need = (unsigned)((size + ARENA_CODE_SLOT - 1) / ARENA_CODE_SLOT), i, j;

  if (!g_code_max || need > ARENA_CODE_SLOTS_MAX) return (size_t)-1;
  for (i = 0; g_code_slots >= need && i + need <= g_code_slots; i++) {
    for (j = 0; j < need; j++) if (g_code_used[i + j]) break;
    if (j < need) { i += j; continue; }
    for (j = 0; j < need; j++) g_code_used[i + j] = 1;
    return g_code_lo + (size_t)i * ARENA_CODE_SLOT;
  }
  /* No free run: grow the region downward if the images have not reached it
   * and the ceiling allows. Slot 0 stays the lowest, so existing offsets do
   * not move -- the new slots are prepended and the used flags shift up. */
  {
    size_t want = (size_t)need * ARENA_CODE_SLOT;
    size_t new_lo = g_code_lo - want;

    if (g_code_slots + need > ARENA_CODE_SLOTS_MAX) return (size_t)-1;
    if (g_code_hi - new_lo > g_code_max) return (size_t)-1;
    if (new_lo > g_code_lo) return (size_t)-1;                 /* underflow */
    if (new_lo < g_used + (16u << 20)) return (size_t)-1;      /* leave images room */
    if (g_win_lo != (size_t)-1 && new_lo < g_win_hi) return (size_t)-1;
    for (i = g_code_slots; i > 0; i--) g_code_used[i + need - 1] = g_code_used[i - 1];
    for (j = 0; j < need; j++) g_code_used[j] = 1;
    g_code_slots += need;
    g_code_lo = new_lo;
    return new_lo;
  }
}

static int arena_code_give_back(size_t off, size_t size) {
  unsigned first, need, i;

  if (!g_code_slots || off < g_code_lo || off >= g_code_hi) return 0;
  arena_drop_pages(off, size);
  first = (unsigned)((off - g_code_lo) / ARENA_CODE_SLOT);
  need  = (unsigned)((size + ARENA_CODE_SLOT - 1) / ARENA_CODE_SLOT);
  for (i = first; i < first + need && i < g_code_slots; i++) g_code_used[i] = 0;
  return 1;
}

int ios_jit_arena_alloc(size_t size, size_t align, void **exec, void **write) {
  if (!g_ready || !size) return 0;
  if (align < 16) align = 16;

  int reused = 0;
  pthread_mutex_lock(&g_lock);
  /* Big requests are FEX code buffers: a slot first, which cannot fragment,
   * then a freed JIT range. Everything smaller bumps first and falls back to
   * the freed JIT ranges only when the bump is exhausted, so small image views
   * do not fragment the big holes FEX needs. */
  size_t off = size >= (32u << 20) ? arena_code_take(size) : (size_t)-1;
  if (off == (size_t)-1 && size >= (32u << 20)) off = arena_jit_take(size, align);
  if (off == (size_t)-1) {
    off = (g_used + align - 1) & ~(align - 1);
    if (off < g_win_hi && off + size > g_win_lo)
      off = (g_win_hi + align - 1) & ~(align - 1);
    if (g_code_slots && off + size > g_code_lo) off = g_arena.size;  /* bump stops below the slots */
    if (off + size <= g_arena.size) g_used = off + size;
    else off = size < (32u << 20) ? arena_jit_take(size, align) : (size_t)-1;
    if (off == (size_t)-1) {
      pthread_mutex_unlock(&g_lock);
      return 0;   /* exhausted -- caller must fall back, not crash */
    }
    if (off + size != g_used) reused = 1;
  } else reused = 1;
  pthread_mutex_unlock(&g_lock);

  *exec  = (char *)g_arena.exec  + off;
  *write = (char *)g_arena.write + off;
  if (reused) {
    memset(*write, 0, size);                    /* fresh mmap is zero; reuse must be too */
    sys_icache_invalidate(*exec, size);
  }
  return 1;
}

/* Return a range to the arena without unmapping it (keeps the RX blessing).
 * A freed image view is never handed out again: its bits in the EC code bitmap
 * are shared by every process in the task, and reuse would race the x64
 * processes reading them. Its pages are released. */
void ios_jit_arena_free(void *exec, size_t size) {
  size_t off;

  if (!g_ready || !exec || !size) return;
  if ((char *)exec < (char *)g_arena.exec ||
      (char *)exec + size > (char *)g_arena.exec + g_arena.size) return;
  off = (size_t)((char *)exec - (char *)g_arena.exec);
  pthread_mutex_lock(&g_lock);
  if (!arena_code_give_back(off, size)) arena_drop_pages(off, size);
  pthread_mutex_unlock(&g_lock);
}

#define ARENA_JIT_FREE_MAX 2048
struct arena_free_range { size_t off, len; };
static struct arena_free_range g_jit_free[ARENA_JIT_FREE_MAX];
static unsigned g_jit_free_count;

void ios_jit_arena_free_jit(void *exec, size_t size) {
  if (!g_ready || !exec || !size) return;
  if ((char *)exec < (char *)g_arena.exec ||
      (char *)exec + size > (char *)g_arena.exec + g_arena.size) return;
  pthread_mutex_lock(&g_lock);
  if (arena_code_give_back((size_t)((char *)exec - (char *)g_arena.exec), size)) {
    pthread_mutex_unlock(&g_lock);
    return;
  }

  {
    size_t off = (size_t)((char *)exec - (char *)g_arena.exec);
    unsigned i;
    /* merge with a neighbour so a retired child's many small views coalesce */
    for (i = 0; i < g_jit_free_count; i++) {
      if (g_jit_free[i].off + g_jit_free[i].len == off) { g_jit_free[i].len += size; break; }
      if (off + size == g_jit_free[i].off) { g_jit_free[i].off = off; g_jit_free[i].len += size; break; }
    }
    if (i == g_jit_free_count && g_jit_free_count < ARENA_JIT_FREE_MAX) {
      g_jit_free[g_jit_free_count].off = off;
      g_jit_free[g_jit_free_count].len = size;
      g_jit_free_count++;
    }
  }
  pthread_mutex_unlock(&g_lock);
}

static size_t arena_jit_take(size_t size, size_t align) {
  unsigned i, best = ~0u;
  size_t best_len = (size_t)-1;
  for (i = 0; i < g_jit_free_count; i++) {
    size_t base = g_jit_free[i].off, end = base + g_jit_free[i].len;
    size_t aligned = (base + align - 1) & ~(align - 1);
    if (aligned + size > end || g_jit_free[i].len >= best_len) continue;
    best = i; best_len = g_jit_free[i].len;
  }
  for (i = best; i < g_jit_free_count; i = g_jit_free_count) {
    size_t base = g_jit_free[i].off, end = base + g_jit_free[i].len;
    size_t aligned = (base + align - 1) & ~(align - 1);
    size_t tail = end - (aligned + size), head = aligned - base;
    if (tail) { g_jit_free[i].off = aligned + size; g_jit_free[i].len = tail; }
    else { g_jit_free[i] = g_jit_free[--g_jit_free_count]; }
    if (head && g_jit_free_count < ARENA_JIT_FREE_MAX) {
      g_jit_free[g_jit_free_count].off = base; g_jit_free[g_jit_free_count].len = head; g_jit_free_count++;
    }
    return aligned;
  }
  return (size_t)-1;
}

void ios_jit_arena_bounds(void **exec_lo, size_t *size, ptrdiff_t *delta) {
  if (exec_lo) *exec_lo = g_ready ? g_arena.exec : NULL;
  if (size)    *size    = g_ready ? g_arena.size : 0;
  if (delta)   *delta   = g_ready ? g_arena.delta : 0;
}

void ios_jit_arena_publish(void *exec_addr, size_t len) {
  jit_region_publish(&g_arena, exec_addr, len);
}

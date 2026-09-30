#include "jit_alloc.h"

#include <errno.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <libkern/OSCacheControl.h>

/* ---- the brk handshake -------------------------------------------------- */

__attribute__((naked, noinline)) static void jit26_detach(void) {
  __asm__ volatile("mov x16, #0\n"
                   "brk #0xf00d\n"
                   "ret\n");
}

__attribute__((naked, noinline)) static void *jit26_prepare_region(void *addr,
                                                                   size_t len) {
  __asm__ volatile("mov x16, #1\n"
                   "brk #0xf00d\n"
                   "ret\n");
}

/* kitsune.js only: allocate RX without preparing it. Other scripts leave x0
 * as it was, which is NULL here. */
__attribute__((naked, noinline)) static void *jit26_allocate_region(void *addr,
                                                                    size_t len) {
  __asm__ volatile("mov x16, #3\n"
                   "brk #0xf00d\n"
                   "ret\n");
}

static sigjmp_buf g_jmp;
static volatile sig_atomic_t g_sig;

static void trap_handler(int sig) {
  g_sig = sig;
  siglongjmp(g_jmp, 1);
}

/* Runs one brk command with faults trapped: without a debugger the brk raises
 * SIGTRAP instead of returning. */
static int trapped(void *(*command)(void *, size_t), void *addr, size_t len, void **out, int *out_sig) {
  static const int sigs[] = {SIGBUS, SIGSEGV, SIGILL, SIGTRAP};
  struct sigaction old[4], sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = trap_handler;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = SA_NODEFER;
  for (size_t i = 0; i < 4; i++) sigaction(sigs[i], &sa, &old[i]);

  g_sig = 0;
  void *r = NULL;
  if (sigsetjmp(g_jmp, 1) == 0) r = command(addr, len);

  for (size_t i = 0; i < 4; i++) sigaction(sigs[i], &old[i], NULL);
  *out = r;
  *out_sig = (int)g_sig;
  return g_sig == 0;
}

static int handshake(void *addr, size_t len, void **out, int *out_sig) {
  return trapped(jit26_prepare_region, addr, len, out, out_sig);
}

/* ---- public API --------------------------------------------------------- */

static int g_available = 0;

/* Only success is remembered: a debugger with the script can attach later. */
int jit_alloc_available(char *err, size_t errlen) {
  if (g_available) return 1;

  /* One page is enough to learn whether anything answers the breakpoint. */
  size_t page = (size_t)getpagesize();
  void *r = NULL;
  int sig = 0;
  if (!handshake(NULL, page, &r, &sig)) {
    if (err)
      snprintf(err, errlen,
               "brk #0xf00d raised %s (%d): no debugger with the Kitsune JIT "
               "script is attached",
               strsignal(sig), sig);
    return 0;
  }
  if (r) vm_deallocate(mach_task_self(), (vm_address_t)(uintptr_t)r, (vm_size_t)page);
  g_available = 1;
  return 1;
}

int jit_region_alloc(size_t size, jit_region *out, char *err, size_t errlen) {
  return jit_region_alloc_stepwise(size, 0, NULL, NULL, out, err, errlen);
}

/* The debugger allocates the RX region, then prepares it page by page, which
 * is the slow part; `step` 0 asks for both in one request. */
static void *debugger_region(size_t len, size_t step, void (*progress)(double, void *), void *ctx,
                             char *err, size_t errlen) {
  void *rx = NULL;
  int sig = 0;
  if (step && !trapped(jit26_allocate_region, NULL, len, &rx, &sig)) {
    snprintf(err, errlen, "allocate raised %s (%d) for %zu bytes", strsignal(sig), sig, len);
    return NULL;
  }
  if (!rx) {
    if (!handshake(NULL, len, &rx, &sig)) {
      snprintf(err, errlen, "handshake raised %s (%d) for %zu bytes", strsignal(sig), sig, len);
      return NULL;
    }
    if (!rx) snprintf(err, errlen, "handshake returned NULL for %zu bytes", len);
    if (rx && progress) progress(1.0, ctx);
    return rx;
  }
  for (size_t off = 0; off < len; off += step) {
    size_t n = len - off < step ? len - off : step;
    void *done = NULL;
    if (!handshake((char *)rx + off, n, &done, &sig) || done != (char *)rx + off) {
      snprintf(err, errlen, "preparing %zu bytes at +%zu failed (%s)", n, off, sig ? strsignal(sig) : "bad reply");
      vm_deallocate(mach_task_self(), (vm_address_t)(uintptr_t)rx, (vm_size_t)len);
      return NULL;
    }
    if (progress) progress((double)(off + n) / (double)len, ctx);
  }
  return rx;
}

int jit_region_alloc_stepwise(size_t size, size_t step, void (*progress)(double, void *), void *ctx,
                              jit_region *out, char *err, size_t errlen) {
  if (!out) return 0;
  memset(out, 0, sizeof(*out));

  if (!jit_alloc_available(err, errlen)) return 0;

  size_t page = (size_t)getpagesize();
  size_t len = (size + page - 1) & ~(page - 1);
  if (len == 0) len = page;
  step &= ~(page - 1);

  void *rx = debugger_region(len, step, progress, ctx, err, errlen);
  if (!rx) return 0;

  /* A writable alias of the same physical pages. */
  mach_port_t task = mach_task_self();
  vm_address_t alias = 0;
  vm_prot_t cur = VM_PROT_NONE, max = VM_PROT_NONE;
  kern_return_t kr =
      vm_remap(task, &alias, (vm_size_t)len, 0, VM_FLAGS_ANYWHERE, task,
               (vm_address_t)(uintptr_t)rx, FALSE, &cur, &max, VM_INHERIT_NONE);
  if (kr != KERN_SUCCESS) {
    snprintf(err, errlen, "vm_remap failed: %d", kr);
    return 0;
  }
  kr = vm_protect(task, alias, (vm_size_t)len, FALSE,
                  VM_PROT_READ | VM_PROT_WRITE);
  if (kr != KERN_SUCCESS) {
    snprintf(err, errlen, "vm_protect(alias, RW) failed: %d (max=0x%x)", kr,
             max);
    vm_deallocate(task, alias, (vm_size_t)len);
    return 0;
  }

  out->exec = rx;
  out->write = (void *)(uintptr_t)alias;
  out->delta = (char *)out->write - (char *)out->exec;
  out->size = len;
  return 1;
}

void jit_region_free(jit_region *r) {
  if (!r || !r->write) return;
  vm_deallocate(mach_task_self(), (vm_address_t)(uintptr_t)r->write,
                (vm_size_t)r->size);
  memset(r, 0, sizeof(*r));
}

void jit_region_publish(const jit_region *r, void *exec_addr, size_t len) {
  (void)r;
  sys_icache_invalidate(exec_addr, len);
}

int jit_detach(char *err, size_t errlen) {
  static const int sigs[] = {SIGBUS, SIGSEGV, SIGILL, SIGTRAP};
  struct sigaction old[4], sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = trap_handler;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = SA_NODEFER;
  for (size_t i = 0; i < 4; i++) sigaction(sigs[i], &sa, &old[i]);

  g_sig = 0;
  if (sigsetjmp(g_jmp, 1) == 0) jit26_detach();

  for (size_t i = 0; i < 4; i++) sigaction(sigs[i], &old[i], NULL);

  if (g_sig) {
    snprintf(err, errlen, "detach brk raised %s (%d)", strsignal((int)g_sig),
             (int)g_sig);
    return 0;
  }
  /* Further blessing is impossible now. */
  g_available = 0;
  return 1;
}

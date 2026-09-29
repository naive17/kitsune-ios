/* macOS/arm64 model of the iOS saved-signal-frame overlap. No corrupting write. */
#include <assert.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/ucontext.h>

static volatile sig_atomic_t overlap, on_altstack;
static uintptr_t alt_start, alt_end;
static void handler(int sig, siginfo_t *info, void *arg) {
    (void)sig; (void)info;
    ucontext_t *ctx = arg;
    uintptr_t saved_sp = ctx->uc_mcontext->__ss.__sp & ~(uintptr_t)15;
    uintptr_t exception_start = saved_sp - 0x460;
    uintptr_t ctx_start = (uintptr_t)ctx, mc_start = (uintptr_t)ctx->uc_mcontext;
    overlap = (ctx_start < saved_sp && ctx_start + sizeof(*ctx) > exception_start) ||
              (mc_start < saved_sp && mc_start + sizeof(*ctx->uc_mcontext) > exception_start);
    on_altstack = ctx_start >= alt_start && ctx_start < alt_end;
}
int main(void) {
    size_t size = 128 * 1024;
    void *memory = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(memory != MAP_FAILED);
    alt_start = (uintptr_t)memory; alt_end = alt_start + size;
    stack_t ss = {.ss_sp = memory, .ss_size = size};
    assert(!sigaltstack(&ss, NULL));
    struct sigaction action = {.sa_sigaction = handler, .sa_flags = SA_SIGINFO};
    sigemptyset(&action.sa_mask);
    assert(!sigaction(SIGUSR1, &action, NULL));
    raise(SIGUSR1);
    printf("normal stack: saved-frame overlap=%d, on-altstack=%d\n", overlap, on_altstack);
    assert(overlap && !on_altstack);
    action.sa_flags |= SA_ONSTACK;
    assert(!sigaction(SIGUSR1, &action, NULL));
    raise(SIGUSR1);
    printf("alternate stack: saved-frame overlap=%d, on-altstack=%d\n", overlap, on_altstack);
    assert(!overlap && on_altstack);
    ss.ss_flags = SS_DISABLE;
    assert(!sigaltstack(&ss, NULL));
    munmap(memory, size);
    puts("PASS: alternate signal stack separates Wine's exception payload from Darwin's saved context");
}

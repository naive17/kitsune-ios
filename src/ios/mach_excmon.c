#include "mach_excmon.h"
#include "jit_arena.h"

#include <mach/mach.h>
#include <mach/exception_types.h>
#include <mach/task.h>
#include <mach/thread_status.h>
#include <mach/arm/thread_status.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <sys/syscall.h>

/* ---- state -------------------------------------------------------------- */

static int          g_fd     = -1;
static mach_port_t  g_port    = MACH_PORT_NULL;
static volatile int g_logged  = 0;   /* rate-limit the register dumps */

/* previous task exception ports, saved for reference (not chained) */
static struct {
    mach_msg_type_number_t count;
    exception_mask_t       masks[EXC_TYPES_COUNT];
    mach_port_t            ports[EXC_TYPES_COUNT];
    exception_behavior_t   behaviors[EXC_TYPES_COUNT];
    thread_state_flavor_t  flavors[EXC_TYPES_COUNT];
} g_old;

#define WLOG(...) do {                                                     \
        char _b[600];                                                     \
        int _n = snprintf(_b, sizeof(_b), __VA_ARGS__);                   \
        if (_n > 0 && g_fd >= 0) {                                        \
            ssize_t _w = write(g_fd, _b, (size_t)_n); (void)_w;           \
        }                                                                 \
    } while (0)

static const char *exc_name(exception_type_t e) {
    switch (e) {
        case EXC_BAD_ACCESS:      return "EXC_BAD_ACCESS";
        case EXC_BAD_INSTRUCTION: return "EXC_BAD_INSTRUCTION";
        case EXC_ARITHMETIC:      return "EXC_ARITHMETIC";
        case EXC_EMULATION:       return "EXC_EMULATION";
        case EXC_SOFTWARE:        return "EXC_SOFTWARE";
        case EXC_BREAKPOINT:      return "EXC_BREAKPOINT";
        case EXC_SYSCALL:         return "EXC_SYSCALL";
        case EXC_MACH_SYSCALL:    return "EXC_MACH_SYSCALL";
        case EXC_RPC_ALERT:       return "EXC_RPC_ALERT";
        case EXC_CRASH:           return "EXC_CRASH";
        case EXC_RESOURCE:        return "EXC_RESOURCE";
        case EXC_GUARD:           return "EXC_GUARD";
        case EXC_CORPSE_NOTIFY:   return "EXC_CORPSE_NOTIFY";
        default:                  return "EXC_?";
    }
}

/* Name the region a PC or fault address lands in, so the log reads without a
 * map. The arena and its RW alias are wherever jit_arena.c placed them; the
 * pool and band bounds are the ones ntdll's virtual.c uses on iOS. */
static const char *region_of(uint64_t a) {
    void *lo = NULL;
    size_t size = 0;
    ptrdiff_t delta = 0;
    uint64_t exec;

    ios_jit_arena_bounds(&lo, &size, &delta);
    exec = (uint64_t)(uintptr_t)lo;
    if (a >= 0x120000000ULL && a < 0x120010000ULL) return "KUSER_SHARED";
    if (size && a >= exec && a < exec + size) return "JIT-ARENA(exec)";
    if (size && a >= exec + (uint64_t)delta && a < exec + (uint64_t)delta + size) return "JIT-ALIAS(rw)";
    if (a >= 0x7000000000ULL && a < 0x7400000000ULL) return "BIGPOOL";
    if (a >= 0x7400000000ULL && a < 0x8000000000ULL) return "BAND";
    if (a >= 0x100000000ULL && a < 0x120000000ULL) return "host-image";
    if (a != 0 && a < 0x100000000ULL)              return "low/near-null";
    return "other";
}

/* Exception message for EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES. Hand-rolled so
 * no MIG generation step is needed. codeCnt is normally 2: code[0] is the
 * exception subtype (KERN_* for BAD_ACCESS), code[1] the faulting address. */
#pragma pack(4)
typedef struct {
    mach_msg_header_t          Head;
    mach_msg_body_t            msgh_body;
    mach_msg_port_descriptor_t thread;
    mach_msg_port_descriptor_t task;
    NDR_record_t               NDR;
    exception_type_t           exception;
    mach_msg_type_number_t     codeCnt;
    int64_t                    code[4];
    char                       trailer[96];
} exc_request_t;

typedef struct {
    mach_msg_header_t Head;
    NDR_record_t      NDR;
    kern_return_t     RetCode;
} exc_reply_t;
#pragma pack()

static void log_thread_state(mach_port_t thread) {
    arm_thread_state64_t ts;
    mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, ARM_THREAD_STATE64,
                         (thread_state_t)&ts, &cnt) != KERN_SUCCESS) {
        WLOG("  (thread_get_state failed)\n");
        return;
    }
    uint64_t pc = (uint64_t)arm_thread_state64_get_pc(ts);
    uint64_t lr = (uint64_t)arm_thread_state64_get_lr(ts);
    uint64_t sp = (uint64_t)arm_thread_state64_get_sp(ts);
    uint64_t fp = (uint64_t)arm_thread_state64_get_fp(ts);
    WLOG("  pc=0x%llx [%s]  lr=0x%llx  sp=0x%llx  fp=0x%llx  cpsr=0x%08x\n",
         (unsigned long long)pc, region_of(pc),
         (unsigned long long)lr, (unsigned long long)sp,
         (unsigned long long)fp, (unsigned)ts.__cpsr);
    for (int i = 0; i < 29; i += 5) {
        WLOG("  x%-2d=0x%llx x%-2d=0x%llx x%-2d=0x%llx x%-2d=0x%llx x%-2d=0x%llx\n",
             i,   (unsigned long long)ts.__x[i],
             i+1, (unsigned long long)(i+1 < 29 ? ts.__x[i+1] : 0),
             i+2, (unsigned long long)(i+2 < 29 ? ts.__x[i+2] : 0),
             i+3, (unsigned long long)(i+3 < 29 ? ts.__x[i+3] : 0),
             i+4, (unsigned long long)(i+4 < 29 ? ts.__x[i+4] : 0));
    }
}

static void *exc_server_thread(void *arg) {
    (void)arg;
    for (;;) {
        exc_request_t req;
        memset(&req, 0, sizeof(req));
        req.Head.msgh_local_port = g_port;
        req.Head.msgh_size       = sizeof(req);

        kern_return_t kr = mach_msg(&req.Head, MACH_RCV_MSG, 0, sizeof(req),
                                    g_port, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        if (kr != KERN_SUCCESS) continue;

        mach_port_t      thread = req.thread.name;
        exception_type_t exc    = req.exception;
        int64_t c0 = req.codeCnt > 0 ? req.code[0] : 0;
        int64_t c1 = req.codeCnt > 1 ? req.code[1] : 0;

        if (g_logged < 24) {
            g_logged++;
            WLOG("MACH-EXC #%d %s(%d) subcode=0x%llx addr=0x%llx [%s]\n",
                 g_logged, exc_name(exc), (int)exc,
                 (unsigned long long)c0,
                 (unsigned long long)c1, region_of((uint64_t)c1));
            log_thread_state(thread);
        }

        /* Don't leak the send rights the kernel handed us. */
        if (req.thread.name != MACH_PORT_NULL)
            mach_port_deallocate(mach_task_self(), req.thread.name);
        if (req.task.name != MACH_PORT_NULL)
            mach_port_deallocate(mach_task_self(), req.task.name);

        /* Decline: let the kernel apply the default action (BSD signal / task
         * terminate). We are a tap, not a handler -- we do not try to recover. */
        exc_reply_t rep;
        memset(&rep, 0, sizeof(rep));
        rep.Head.msgh_bits        = MACH_MSGH_BITS(MACH_MSGH_BITS_REMOTE(req.Head.msgh_bits), 0);
        rep.Head.msgh_remote_port = req.Head.msgh_remote_port;
        rep.Head.msgh_local_port  = MACH_PORT_NULL;
        rep.Head.msgh_size        = sizeof(rep);
        rep.Head.msgh_id          = req.Head.msgh_id + 100;
        rep.NDR                   = req.NDR;
        rep.RetCode               = KERN_FAILURE;
        mach_msg(&rep.Head, MACH_SEND_MSG, sizeof(rep), 0, MACH_PORT_NULL,
                 MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    }
    return NULL;
}

int MachExcMon_Install(int log_fd) {
    g_fd = log_fd;

    mach_port_t self = mach_task_self();

    if (mach_port_allocate(self, MACH_PORT_RIGHT_RECEIVE, &g_port) != KERN_SUCCESS)
        { WLOG("MACH-EXC install FAILED: port_allocate\n"); return -1; }
    if (mach_port_insert_right(self, g_port, g_port, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS)
        { WLOG("MACH-EXC install FAILED: insert_right\n"); return -1; }

    exception_mask_t mask = EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION |
                            EXC_MASK_ARITHMETIC | EXC_MASK_GUARD |
                            EXC_MASK_CORPSE_NOTIFY | EXC_MASK_RESOURCE;

    /* Save-and-set so the previous ports are on record. */
    g_old.count = EXC_TYPES_COUNT;
    kern_return_t kr = task_swap_exception_ports(
        self, mask, g_port,
        (exception_behavior_t)(EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES),
        ARM_THREAD_STATE64,
        g_old.masks, &g_old.count, g_old.ports, g_old.behaviors, g_old.flavors);
    if (kr != KERN_SUCCESS) {
        WLOG("MACH-EXC install FAILED: swap_exception_ports kr=%d\n", (int)kr);
        return -1;
    }

    pthread_t th;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 512 * 1024);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    int rc = pthread_create(&th, &attr, exc_server_thread, NULL);
    pthread_attr_destroy(&attr);
    if (rc != 0) { WLOG("MACH-EXC install FAILED: pthread_create rc=%d\n", rc); return -1; }

    WLOG("MACH-EXC installed: task port armed for BAD_ACCESS|BAD_INSTR|ARITH|"
         "GUARD|CORPSE|RESOURCE (NOT breakpoint); prev_ports=%u\n",
         (unsigned)g_old.count);
    return 0;
}

#define DYLD_INTERPOSE(_repl, _orig)                                          \
    __attribute__((used)) static struct {                                    \
        const void *repl; const void *orig;                                  \
    } _interpose_##_orig __attribute__((section("__DATA,__interpose"))) =     \
        { (const void *)(uintptr_t)&_repl, (const void *)(uintptr_t)&_orig };

static void log_exit_call(const char *what, int code) {
    WLOG("EXIT-CALL %s(%d) -- something is tearing the process down:\n", what, code);
    void *fr[32];
    int nf = backtrace(fr, 32);
    char **s = backtrace_symbols(fr, nf);
    for (int i = 0; i < nf && s; i++)
        WLOG("  #%02d %s\n", i, s[i]);
}

static void ios_exit(int code) {
    log_exit_call("exit", code);
    void (*real)(int) = (void (*)(int))dlsym(RTLD_NEXT, "exit");
    if (real) real(code);
    syscall(SYS_exit, code);
    __builtin_unreachable();
}
static void ios__Exit(int code) {
    log_exit_call("_Exit", code);
    void (*real)(int) = (void (*)(int))dlsym(RTLD_NEXT, "_Exit");
    if (real) real(code);
    syscall(SYS_exit, code);
    __builtin_unreachable();
}
static void ios__exit(int code) {
    log_exit_call("_exit", code);
    void (*real)(int) = (void (*)(int))dlsym(RTLD_NEXT, "_exit");
    if (real) real(code);
    syscall(SYS_exit, code);
    __builtin_unreachable();
}
static void ios_abort(void) {
    log_exit_call("abort", 0);
    void (*real)(void) = (void (*)(void))dlsym(RTLD_NEXT, "abort");
    if (real) real();
    syscall(SYS_exit, 134);
    __builtin_unreachable();
}

DYLD_INTERPOSE(ios_exit,  exit)
DYLD_INTERPOSE(ios__Exit, _Exit)
DYLD_INTERPOSE(ios__exit, _exit)
DYLD_INTERPOSE(ios_abort, abort)

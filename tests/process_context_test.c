/* Real production context + server wrappers, with simulated Wine identities.
 * Socket ownership/lifetime and pthread concurrency use real OS primitives.
 * This is NOT a private PE loader or Windows child-process integration test. */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <signal.h>
#include <stdlib.h>
#include <errno.h>
#include <sys/socket.h>
static int fail_allocation;
static void *context_calloc(size_t count, size_t size)
{
    if (fail_allocation) { fail_allocation = 0; errno = ENOMEM; return NULL; }
    return calloc(count, size);
}
#define calloc context_calloc
#include "ios_process_context.h"
#undef calloc

typedef uint32_t NTSTATUS;
typedef uint32_t DWORD;
typedef void PEB;
struct ios_process_state { int marker; int child; };
static struct ios_process_state ios_root_state;
static struct ios_process_state state_a = {.marker=40}, state_b = {.marker=44};
typedef int BOOL;
#define TRUE 1
#define FALSE 0
#define STATUS_SUCCESS 0
#define STATUS_INVALID_PARAMETER 0xc000000du
#define STATUS_PROCESS_IS_TERMINATING 0xc000010au
#define ULongToHandle(value) ((void *)(uintptr_t)(value))
struct client_id { void *UniqueProcess; };
struct test_teb { void *Peb; struct client_id RealClientId, ClientId; };
struct thread_data { struct test_teb *teb; struct ios_process_context *ios_process; };
static _Thread_local struct thread_data *current;
static struct thread_data *get_thread_data(void) { return current; }
static int fd_socket = -1;
static BOOL ios_fd_cache_enabled = TRUE, process_exiting;
static sigset_t server_block_set;
/* Stubs for reaper code now sliced from server.c (§34 arena reclamation). */
#ifndef ERR
#define ERR(...) ((void)0)
#endif
static unsigned reclaim_calls;
static void ios_reclaim_owner_arena_views( void *peb ) { (void)peb; reclaim_calls++; }
/* The reaper frees each joined thread's data (stack, TEB); counted here. */
static unsigned freed_thread_data;
static void virtual_free_thread_data( struct thread_data *data ) { (void)data; freed_thread_data++; }
#include "wine-process-context.inc"
/* The reaper also retires the child's fd cache, defined outside the slice. */
static unsigned int ios_retire_fd_cache( const void *peb ) { (void)peb; return 0; }

static int owner_a, owner_b;
static int callback_a[IOS_CALLBACK_COUNT], callback_b[IOS_CALLBACK_COUNT];
static void bind_callbacks(struct ios_process_context *ctx, int *sentinels)
{
    void *callbacks[IOS_CALLBACK_COUNT];
    for (unsigned i = 0; i < IOS_CALLBACK_COUNT; ++i) callbacks[i] = &sentinels[i];
    callbacks[IOS_CALLBACK_KiUserEmulationDispatcher] = NULL; /* native process */
    assert(!ios_proc_callback(ctx, IOS_CALLBACK_LdrInitializeThunk));
    callbacks[IOS_CALLBACK_DbgUiRemoteBreakin] = NULL;
    assert(ios_proc_init_callbacks(ctx, callbacks) == EINVAL);
    assert(!ios_proc_callback(ctx, IOS_CALLBACK_LdrInitializeThunk));
    callbacks[IOS_CALLBACK_DbgUiRemoteBreakin] = &sentinels[IOS_CALLBACK_DbgUiRemoteBreakin];
    assert(!ios_proc_inherit(ctx));
    assert(ios_proc_init_callbacks(ctx, callbacks) == EBUSY); /* already published siblings */
    assert(!ios_proc_release_islast(ctx)); /* the owner's reference remains */
    assert(!ios_proc_init_callbacks(ctx, callbacks));
    assert(ios_proc_init_callbacks(ctx, callbacks) == EBUSY); /* immutable */
    assert(!ios_proc_callback(ctx, IOS_CALLBACK_KiUserEmulationDispatcher));
    assert(!ios_proc_callback(ctx, (enum ios_process_callback)-1));
    pthread_mutex_lock(&ctx->lock);
    assert(ios_proc_callback(ctx, IOS_CALLBACK_LdrInitializeThunk) ==
           &sentinels[IOS_CALLBACK_LdrInitializeThunk]); /* signal read cannot take this lock */
    pthread_mutex_unlock(&ctx->lock);
}
static struct ios_process_context *make_context(void *owner, unsigned int pid, int pair[2])
{
    struct ios_process_context *ctx;
    assert(!socketpair(AF_UNIX, SOCK_STREAM, 0, pair));
    ctx = ios_proc_create(owner, pair[0]);
    assert(ctx && (fcntl(pair[0], F_GETFD) & FD_CLOEXEC));
    assert(ios_proc_inherit(ctx) == EBUSY); /* cannot publish before server identity */
    assert(!ios_proc_set_pid(ctx, pid));
    assert(ios_proc_set_pid(ctx, pid + 1) == EINVAL);
    return ctx;
}
static void assert_closed(int fd)
{
    errno = 0;
    assert(fcntl(fd, F_GETFD) == -1 && errno == EBADF);
}
static void *worker(void *arg)
{
    struct thread_data *data = arg;
    current = data; /* equivalent to Wine's thread_data_key binding */
    assert(current_fd_socket() == data->ios_process->socket);
    assert(!data->teb); /* a real pthread simulating a TEB-less Wine system worker */
    for (unsigned i = 0; i < 1000; ++i)
    {
        assert(ios_process_current_peb(&owner_a) == &owner_b);
        assert(ios_process_current_pid(0x40) == 0x44);
        assert(ios_current_process_state() == &state_b);
        assert(ios_process_current_callback(IOS_CALLBACK_LdrInitializeThunk, &owner_a) ==
               &callback_b[IOS_CALLBACK_LdrInitializeThunk]);
        struct thread_data sibling = {0};
        assert(!ios_process_inherit_thread(&sibling));
        assert(sibling.ios_process == data->ios_process);
        ios_process_release_thread(&sibling); /* failed create / completed sibling */
        ios_process_release_thread(&sibling); /* idempotent thread wrapper */
    }
    ios_process_release_thread(data);
    return NULL;
}
int main(void)
{
    int a[2], b[2], empty[2];
    char byte;
    struct thread_data root_a = {0}, root_b = {0}, sibling = {0};
    struct test_teb teb = {0};
    struct ios_process_context *ctx;
    assert(!sigemptyset(&server_block_set));
    assert(!sigaddset(&server_block_set, SIGUSR1));

    assert(!ios_proc_create(NULL, 0) && errno == EINVAL);
    assert(!ios_proc_create(&owner_a, -1) && errno == EINVAL);
    assert(!socketpair(AF_UNIX, SOCK_STREAM, 0, empty));
    assert(!ios_proc_create(NULL, empty[0]));
    assert(fcntl(empty[0], F_GETFD) >= 0); /* failure does not consume caller fd */
    fail_allocation = 1;
    assert(!ios_proc_create(&owner_a, empty[0]) && errno == ENOMEM);
    assert(fcntl(empty[0], F_GETFD) >= 0);
    close(empty[0]); close(empty[1]);

    int saved_stdin = dup(0);
    assert(saved_stdin >= 0 && !socketpair(AF_UNIX, SOCK_STREAM, 0, empty));
    assert(dup2(empty[0], 0) == 0); close(empty[0]);
    ctx = ios_proc_create(&owner_a, 0);
    assert(ctx && ios_proc_release_islast(ctx)); ios_proc_destroy(ctx); assert_closed(0);
    assert(dup2(saved_stdin, 0) == 0); close(saved_stdin); close(empty[1]);

    root_a.ios_process = make_context(&owner_a, 0x40, a);
    root_b.ios_process = make_context(&owner_b, 0x44, b);
    root_a.ios_process->state = &state_a;
    root_b.ios_process->state = &state_b;
    bind_callbacks(root_a.ios_process, callback_a);
    bind_callbacks(root_b.ios_process, callback_b);
    current = &root_a;
    assert(ios_process_current_peb(&owner_b) == &owner_a);
    assert(ios_process_current_pid(0x44) == 0x40);
    assert(ios_current_process_state() == &state_a);
    assert(ios_process_current_callback(IOS_CALLBACK_LdrInitializeThunk, &owner_b) ==
           &callback_a[IOS_CALLBACK_LdrInitializeThunk]);
    assert(!ios_process_inherit_thread(&sibling));
    sibling.teb = &teb;
    ios_process_bind_thread_id(&sibling);
    assert(teb.Peb == &owner_a && teb.ClientId.UniqueProcess == ULongToHandle(0x40));
    assert(teb.RealClientId.UniqueProcess == teb.ClientId.UniqueProcess);
    assert(write(current_fd_socket(), "a", 1) == 1 && read(a[1], &byte, 1) == 1 && byte == 'a');
    current = &root_b;
    assert(write(current_fd_socket(), "b", 1) == 1 && read(b[1], &byte, 1) == 1 && byte == 'b');
    current = NULL;
    fd_socket = b[0]; /* even a valid fallback is forbidden in experimental mode */
    assert(current_fd_socket() == -1 && ios_process_exit_state(FALSE));
    assert(!ios_process_current_peb(&owner_a) && !ios_process_current_pid(0x40));
    assert(!ios_current_process_state());
    assert(!ios_process_current_callback(IOS_CALLBACK_LdrInitializeThunk, &owner_a));
    current = &root_a;
    assert(ios_process_exit_state(TRUE));
    assert(ios_proc_inherit(root_a.ios_process) == EBUSY);
    assert(!ios_proc_is_exiting(root_b.ios_process));
    ios_process_release_thread(&root_a); /* sibling keeps socket alive */
    current = &sibling;
    assert(write(current_fd_socket(), "s", 1) == 1 && read(a[1], &byte, 1) == 1 && byte == 's');
    ios_process_release_thread(&sibling);
    assert_closed(a[0]);
    assert(read(a[1], &byte, 1) == 0); /* last reference causes actual peer EOF */
    assert(fcntl(b[0], F_GETFD) >= 0); /* owner B was not touched */
    close(a[1]);

    current = &root_b;
    pthread_t threads[8];
    struct thread_data workers[8] = {{0}};
    for (unsigned i = 0; i < 8; ++i)
    {
        assert(!ios_process_inherit_thread(&workers[i]));
        assert(!pthread_create(&threads[i], NULL, worker, &workers[i]));
    }
    /* Parent can disappear while inherited Unix workers are still running. */
    ios_process_release_thread(&root_b);
    for (unsigned i = 0; i < 8; ++i) assert(!pthread_join(threads[i], NULL));
    assert_closed(b[0]); close(b[1]);

    /* No 64-slot registry or stale PEB entry: reuse one identity 200 times. */
    for (unsigned i = 0; i < 200; ++i)
    {
        ctx = make_context(&owner_a, i + 1, a);
        assert(ios_proc_release_islast(ctx));
        ios_proc_destroy(ctx);
        assert_closed(a[0]); close(a[1]);
    }
    /* Preserve the default path without requiring any context. */
    ios_fd_cache_enabled = FALSE;
    current = NULL; fd_socket = 123;
    assert(current_fd_socket() == 123);
    assert(ios_current_process_state() == &ios_root_state);
    assert(ios_process_current_peb(&owner_a) == &owner_a && ios_process_current_pid(0x40) == 0x40);
    assert(ios_process_current_callback(IOS_CALLBACK_LdrInitializeThunk, &owner_a) == &owner_a);
    assert(!ios_process_inherit_thread(&sibling) && !sibling.ios_process);
    assert(ios_process_exit_state(TRUE) && process_exiting);
    puts("PASS: process transport/PEB/PID/callback isolation, immutable publication, TEB-less inheritance, final-owner EOF, exit isolation, fd0/OOM, 8000 concurrent retains/dispatch reads and 200 lifetimes");
}

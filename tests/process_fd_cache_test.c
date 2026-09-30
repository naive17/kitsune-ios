/* Host tests of Wine's ACTUAL add/get/remove helpers and the per-process
 * FD cache registry, extracted by process-fd-cache-test.mjs. Not a Wine child
 * boot. */
#include "config.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include "ntstatus.h"
#include "windef.h"
#include "winnt.h"
#include "wine/server.h"
#include "wine/debug.h"

WINE_DEFAULT_DEBUG_CHANNEL(server);
int __cdecl __wine_dbg_output(const char *text) { return fputs(text, stderr); }
int __cdecl __wine_dbg_header(enum __wine_debug_class cls, struct __wine_debug_channel *channel,
                             const char *function) {
    (void)cls; (void)channel; (void)function; return -1;
}

/* Simulate TEB->PEB ownership only. The cache and Wine's handle encoding below
 * are production code, not a second implementation of either algorithm. */
struct test_teb { void *Peb; };
struct thread_data { struct test_teb *teb; };
static _Thread_local struct test_teb test_teb;
static _Thread_local struct thread_data thread_data;
/* The actual cache owner now comes from the retained process context, which
 * also exists on Unix/system workers without a TEB. Simulate only identity. */
struct ios_process_context { void *peb; };
static _Thread_local struct ios_process_context test_process;
static struct ios_process_context *ios_current_process(void) {
    return test_process.peb ? &test_process : NULL;
}
static void select_owner(void *owner) {
    test_process.peb = owner; test_teb.Peb = owner; thread_data.teb = &test_teb;
}
static pthread_mutex_t cache_mutex = PTHREAD_MUTEX_INITIALIZER;
static BOOL ios_fd_cache_enabled = TRUE;
static int fail_calloc, fail_mmap;
static unsigned int mapped_blocks, unmapped_blocks;
static void *test_calloc(size_t count, size_t size) {
    if (fail_calloc) { --fail_calloc; return NULL; }
    return calloc(count, size);
}
static void *anon_mmap_alloc(size_t size, int prot) {
    if (fail_mmap) { --fail_mmap; return MAP_FAILED; }
    void *result = mmap(NULL, size, prot, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (result != MAP_FAILED) ++mapped_blocks;
    return result;
}
static int test_munmap(void *address, size_t size) {
    int result = munmap(address, size);
    assert(!result); ++unmapped_blocks; return result;
}
static inline LONG64 interlocked_xchg64(LONG64 *dest, LONG64 value) {
    return __atomic_exchange_n(dest, value, __ATOMIC_SEQ_CST);
}
#define calloc test_calloc
#define munmap test_munmap
#include "wine-fd-cache.inc"
#undef calloc
#undef munmap

static const HANDLE handle = (HANDLE)(ULONG_PTR)0x40;
static int owner_a, owner_b;
static int file_with(char byte) {
    char name[] = "/tmp/kitsune-cache-XXXXXX";
    int fd = mkstemp(name);
    assert(fd >= 0 && !unlink(name) && write(fd, &byte, 1) == 1);
    return fd;
}
static void expect_byte(HANDLE h, char expected) {
    int fd = -1;
    char byte = 0;
    unsigned int access, options;
    enum server_fd_type type;
    assert(get_cached_fd(h, &fd, &type, &access, &options) == STATUS_SUCCESS);
    assert(type == FD_TYPE_FILE && access == 3 && options == 0x123456);
    assert(pread(fd, &byte, 1, 0) == 1 && byte == expected);
}
static void put_file(HANDLE h, int fd) {
    assert(add_fd_to_cache(h, fd, FD_TYPE_FILE, 3, 0x123456));
}
static void expect_miss(HANDLE h) {
    int fd = -1;
    assert(get_cached_fd(h, &fd, NULL, NULL, NULL) == STATUS_INVALID_HANDLE);
    assert(fd == -1);
}

static pthread_mutex_t phase_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t phase_cond = PTHREAD_COND_INITIALIZER;
static int phase;
static void wait_phase(int wanted) {
    assert(!pthread_mutex_lock(&phase_mutex));
    while (phase < wanted) assert(!pthread_cond_wait(&phase_cond, &phase_mutex));
    assert(!pthread_mutex_unlock(&phase_mutex));
}
static void set_phase(int value) {
    assert(!pthread_mutex_lock(&phase_mutex));
    phase = value;
    assert(!pthread_cond_broadcast(&phase_cond));
    assert(!pthread_mutex_unlock(&phase_mutex));
}
static void *reader_thread(void *unused) {
    (void)unused; select_owner(&owner_a);
    assert(!pthread_mutex_lock(&cache_mutex)); expect_byte(handle, 'A');
    assert(!pthread_mutex_unlock(&cache_mutex));
    set_phase(1); wait_phase(2);
    assert(!pthread_mutex_lock(&cache_mutex)); expect_byte(handle, 'B');
    assert(!pthread_mutex_unlock(&cache_mutex));
    return NULL;
}
static void *closer_thread(void *unused) {
    (void)unused; select_owner(&owner_a); wait_phase(1);
    assert(!pthread_mutex_lock(&cache_mutex));
    int fd = remove_fd_from_cache(handle);
    assert(fd >= 0 && !close(fd));
    put_file(handle, file_with('B'));
    assert(!pthread_mutex_unlock(&cache_mutex));
    set_phase(2); return NULL;
}

static void *concurrent_owner(void *owner) {
    select_owner(owner);
    char value = 'a' + *(int *)owner;
    for (unsigned int i = 0; i < 100; ++i) {
        int fd = file_with(value);
        assert(!pthread_mutex_lock(&cache_mutex));
        put_file(handle, fd);
        assert(!pthread_mutex_unlock(&cache_mutex));
        sched_yield(); /* leave this cache live while siblings create/retire */
        assert(!pthread_mutex_lock(&cache_mutex));
        expect_byte(handle, value);
        assert(remove_fd_from_cache(handle) == fd && !close(fd));
        ios_release_fd_cache(owner);
        assert(!pthread_mutex_unlock(&cache_mutex));
    }
    return NULL;
}

int main(void) {
    (void)__wine_dbch___default;
    setvbuf(stdout, NULL, _IONBF, 0);
    puts("START: production Wine process-cache helper tests");
    int fd, sentinel, ignored;
    pthread_t reader, closer, workers[8];
    int identities[IOS_MAX_FD_CACHES + 1];
    for (unsigned int i = 0; i <= IOS_MAX_FD_CACHES; ++i) identities[i] = i;

    assert(!pthread_mutex_lock(&cache_mutex));
    select_owner(&owner_a); put_file(handle, file_with('A'));
    select_owner(&owner_b); expect_miss(handle); put_file(handle, file_with('Z'));
    assert(!pthread_mutex_unlock(&cache_mutex));
    assert(!pthread_create(&reader, NULL, reader_thread, NULL));
    assert(!pthread_create(&closer, NULL, closer_thread, NULL));
    assert(!pthread_join(reader, NULL) && !pthread_join(closer, NULL));
    assert(!pthread_mutex_lock(&cache_mutex));
    select_owner(&owner_b); expect_byte(handle, 'Z');
    ios_release_fd_cache(&owner_a); ios_release_fd_cache(&owner_b);
    puts("PASS: same-valued handles isolated by PEB; sibling close/reuse visible to original reader");

    /* The decoded fd must be closed, while the next fd must stay alive. */
    select_owner(&owner_a); fd = file_with('C'); sentinel = dup(fd);
    assert(sentinel == fd + 1); put_file(handle, fd);
    assert(add_fd_to_cache((HANDLE)8, sentinel, FD_TYPE_INVALID, 0, 0));
    assert(get_cached_fd((HANDLE)8, &ignored, NULL, NULL, NULL) == (NTSTATUS)sentinel);
    put_file((HANDLE)(ULONG_PTR)((FD_CACHE_BLOCK_SIZE + 1) * 4), file_with('D'));
    ios_release_fd_cache(&owner_a);
    assert(fcntl(fd, F_GETFD) == -1 && errno == EBADF);
    assert(fcntl(sentinel, F_GETFD) >= 0 && !close(sentinel));
    assert(mapped_blocks == 1 && unmapped_blocks == 1);
    ios_release_fd_cache(&owner_a); /* idempotent */

    /* Descriptor zero is a real descriptor, not an empty entry. */
    int old_stdin = dup(STDIN_FILENO);
    fd = file_with('0'); assert(dup2(fd, STDIN_FILENO) == STDIN_FILENO);
    if (fd != STDIN_FILENO) assert(!close(fd));
    put_file(handle, STDIN_FILENO); expect_byte(handle, '0');
    ios_release_fd_cache(&owner_a);
    assert(fcntl(STDIN_FILENO, F_GETFD) == -1 && errno == EBADF);
    if (old_stdin >= 0) { assert(dup2(old_stdin, STDIN_FILENO) == STDIN_FILENO); close(old_stdin); }
    puts("PASS: cleanup decodes fd+1, preserves adjacent/error fds, closes fd 0, munmaps extra blocks");

    for (unsigned int i = 0; i < IOS_MAX_FD_CACHES; ++i) {
        select_owner(&identities[i]); put_file(handle, file_with('F'));
    }
    select_owner(&identities[IOS_MAX_FD_CACHES]); fd = file_with('U');
    assert(!add_fd_to_cache(handle, fd, FD_TYPE_FILE, 3, 0));
    expect_miss(handle); assert(remove_fd_from_cache(handle) == -1);
    assert(fcntl(fd, F_GETFD) >= 0 && !close(fd)); /* caller owns uncached fd */
    select_owner(&identities[0]); expect_byte(handle, 'F');
    for (unsigned int i = 0; i < IOS_MAX_FD_CACHES; ++i) ios_release_fd_cache(&identities[i]);
    for (unsigned int i = 0; i < 200; ++i) {
        select_owner(&owner_a); put_file(handle, file_with('R')); ios_release_fd_cache(&owner_a);
    }
    puts("PASS: capacity overflow is truly uncached; 200 owner retire/recreate cycles reuse slots");

    select_owner(&owner_a); put_file(handle, file_with('P'));
    select_owner(&owner_b); fail_calloc = 1; fd = file_with('U');
    assert(!add_fd_to_cache(handle, fd, FD_TYPE_FILE, 3, 0) && !fail_calloc);
    expect_miss(handle); assert(fcntl(fd, F_GETFD) >= 0 && !close(fd));
    select_owner(&owner_a); expect_byte(handle, 'P');
    fail_mmap = 1; fd = file_with('U');
    HANDLE high = (HANDLE)(ULONG_PTR)((FD_CACHE_BLOCK_SIZE + 1) * 4);
    assert(!add_fd_to_cache(high, fd, FD_TYPE_FILE, 3, 0) && !fail_mmap);
    expect_miss(high); assert(!close(fd));
    expect_miss((HANDLE)(ULONG_PTR)-4);
    ios_release_fd_cache(&owner_a);
    select_owner(NULL); fd = file_with('U');
    assert(!add_fd_to_cache(handle, fd, FD_TYPE_FILE, 3, 0)); expect_miss(handle); close(fd);
    puts("PASS: allocation failure, unmapped blocks and unbound threads never borrow another owner's cache");
    assert(!pthread_mutex_unlock(&cache_mutex));

    for (unsigned int i = 0; i < 8; ++i)
        assert(!pthread_create(&workers[i], NULL, concurrent_owner, &identities[i]));
    for (unsigned int i = 0; i < 8; ++i) assert(!pthread_join(workers[i], NULL));
    puts("PASS: 8 concurrent owners / 800 cache create-close-retire cycles");

    /* Disabled experiment keeps upstream's one-process cache unchanged. */
    assert(!pthread_mutex_lock(&cache_mutex));
    ios_fd_cache_enabled = FALSE;
    select_owner(&owner_a); fd = file_with('L'); put_file(handle, fd);
    select_owner(&owner_b); expect_byte(handle, 'L');
    assert(remove_fd_from_cache(handle) == fd && !close(fd));
    assert(!pthread_mutex_unlock(&cache_mutex));
    puts("PASS: default single-process cache behavior preserved");
    return 0;
}

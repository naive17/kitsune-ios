/* Actual server timer functions; all kill/timer calls intercepted, no OS kill. */
#include <assert.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>
#define TICKS_PER_SEC 10000000
#define TIMEOUT_INFINITE INT64_MAX
static int foreground;
static int64_t master_socket_timeout;
#include "wine-inproc-lifetime.inc"
struct process { pid_t unix_pid; int64_t sigkill_delay; void *sigkill_timeout; int refs; };
static unsigned kills, timers, deaths;
static int last_signal;
static void grab_object(struct process *p) { ++p->refs; }
static void process_died(struct process *p) { ++deaths; --p->refs; }
static int fake_kill(pid_t pid, int signal) { assert(pid > 0); ++kills; last_signal = signal; return 0; }
static void *add_timeout_user(int64_t delay, void (*callback)(void *), void *arg)
{
    assert(delay < 0 && callback && arg); ++timers; return (void *)(uintptr_t)1;
}
#define kill fake_kill
#include "wine-process-timer.inc"
#undef kill
int main(void)
{
    master_socket_timeout = -3 * TICKS_PER_SEC;
    configure_inproc_lifetime();
    assert(foreground == 1 && master_socket_timeout == TIMEOUT_INFINITE);
    struct process p = {getpid(), TICKS_PER_SEC / 64, NULL, 1};
    start_sigkill_timer(&p);
#ifdef WINE_IOS_JIT_ARENA
    assert(!kills && !timers && deaths == 1 && p.refs == 1);
    p.refs = 2;
    process_sigkill(&p); /* defensive guard on an already queued host timer */
    assert(!kills && !timers && deaths == 2 && p.refs == 1 && !p.sigkill_timeout);
#else
    assert(!kills && timers == 1 && !deaths && p.refs == 2);
    process_sigkill(&p);
    assert(kills == 1 && last_signal == 0 && timers == 2);
#endif
    kills = timers = deaths = 0;
    p = (struct process){getpid() + 1, TICKS_PER_SEC / 4, NULL, 1};
    start_sigkill_timer(&p); /* distinct extension PID retains normal behavior */
    assert(timers == 1 && !deaths && p.refs == 2);
    process_sigkill(&p);
    assert(kills == 1 && last_signal == SIGKILL && deaths == 1 && p.refs == 1);
    kills = timers = deaths = 0;
    p = (struct process){-1, TICKS_PER_SEC / 64, NULL, 1};
    start_sigkill_timer(&p);
    assert(!kills && !timers && deaths == 1 && p.refs == 1);
    puts("PASS: actual server timer host-PID guard / distinct-PID behavior / balanced references / persistent inproc session");
}

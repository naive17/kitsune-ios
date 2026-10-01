#import "../src/ios/diagnostics.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
  @autoreleasepool {
    KitsuneDiagPolicy off = KitsuneDiagPolicyFor(KitsuneDiagOff);
    assert(off.heartbeat_seconds == 30 && !off.mach_exc_monitor && !off.thread_dumps && !off.guest_sampler);
    assert(!off.log_snapshot && !off.boot_probes);
    assert(!strcmp(off.winedebug_steam, "-all,err+all"));
    assert(KitsuneDiagLaunchEnv(KitsuneDiagOff).count == 0);

    KitsuneDiagPolicy basic = KitsuneDiagPolicyFor(KitsuneDiagBasic);
    assert(basic.heartbeat_seconds == 10 && basic.guest_sampler && !basic.mach_exc_monitor && !basic.thread_dumps);
    assert(!KitsuneDiagLaunchEnv(KitsuneDiagBasic)[@"KITSUNE_THREAD_DUMP"]);

    KitsuneDiagPolicy full = KitsuneDiagPolicyFor(KitsuneDiagFull);
    assert(full.heartbeat_seconds == 5 && full.fine_first_ticks && full.mach_exc_monitor && full.thread_dumps && full.log_snapshot);
    assert(strstr(full.winedebug_steam, "trace+loaddll") && !strstr(full.winedebug_steam, "seh"));
    assert(strstr(full.winedebug_other, "trace+seh"));
    NSDictionary *env = KitsuneDiagLaunchEnv(KitsuneDiagFull);
    assert([env[@"KITSUNE_THREAD_DUMP"] isEqualToString:@"5"]);
    assert([env[@"KITSUNE_METAL_DEBUG"] isEqualToString:@"1"]);
    assert([env[@"KITSUNE_XINPUT_TRACE"] isEqualToString:@"1"]);

    unsetenv("KITSUNE_DIAG_LEVEL");
    assert(KitsuneDiagLevelFromEnv() == KitsuneDiagOff);
    setenv("KITSUNE_DIAG_LEVEL", "1", 1);
    assert(KitsuneDiagLevelFromEnv() == KitsuneDiagBasic);
    setenv("KITSUNE_DIAG_LEVEL", "9", 1);
    assert(KitsuneDiagLevelFromEnv() == KitsuneDiagFull);
    setenv("KITSUNE_DIAG_LEVEL", "-3", 1);
    assert(KitsuneDiagLevelFromEnv() == KitsuneDiagOff);

    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:@"kitsune-diag-test"];
    [ud removePersistentDomainForName:@"kitsune-diag-test"];
    assert(KitsuneDiagLevelStored(ud) == KitsuneDiagOff);
    KitsuneDiagStore(ud, KitsuneDiagBasic);
    assert(KitsuneDiagLevelStored(ud) == KitsuneDiagBasic);
    [ud setInteger:7 forKey:@"kitsune.diag.level"];
    assert(KitsuneDiagLevelStored(ud) == KitsuneDiagFull);
    KitsuneDiagStore(ud, KitsuneDiagBasic);
    unsetenv("KITSUNE_DIAG_LEVEL");
    assert(KitsuneDiagApplyToEnvironment(ud) == KitsuneDiagBasic);
    assert(!strcmp(getenv("KITSUNE_DIAG_LEVEL"), "1"));
    KitsuneDiagStore(ud, KitsuneDiagFull);
    assert(KitsuneDiagApplyToEnvironment(ud) == KitsuneDiagFull && KitsuneDiagLevelFromEnv() == KitsuneDiagFull);
    KitsuneDiagStore(ud, KitsuneDiagOff);
    assert(KitsuneDiagApplyToEnvironment(ud) == KitsuneDiagOff && KitsuneDiagLevelFromEnv() == KitsuneDiagOff);
    [ud removePersistentDomainForName:@"kitsune-diag-test"];

    /* The wedge trigger: a critical-section timeout appended to the wine log. */
    char log[] = "/tmp/kitsune-diag-lock-XXXXXX";
    int fd = mkstemp(log);
    assert(fd >= 0);
    const char *quiet = "0040:err:virtual:map_view ios: jit alloc 0x150010000 size 6000000\n";
    const char *stuck = "0040:err:sync:RtlpWaitForCriticalSection section 0000000129FA0E28 "
        "\"loader.c: loader_section\" wait timed out in thread 0040, blocked by 0170, retrying (60 sec)\n";
    long scanned = 0;
    assert(write(fd, quiet, strlen(quiet)) == (ssize_t)strlen(quiet));
    assert(!KitsuneLogNewLockTimeout(log, (long)strlen(quiet), &scanned) && scanned == (long)strlen(quiet));
    assert(write(fd, stuck, strlen(stuck)) == (ssize_t)strlen(stuck));
    long size = (long)(strlen(quiet) + strlen(stuck));
    assert(KitsuneLogNewLockTimeout(log, size, &scanned) && scanned == size);
    assert(!KitsuneLogNewLockTimeout(log, size, &scanned));  /* already seen */
    assert(ftruncate(fd, 0) == 0 && pwrite(fd, stuck, strlen(stuck), 0) == (ssize_t)strlen(stuck));
    assert(KitsuneLogNewLockTimeout(log, (long)strlen(stuck), &scanned));  /* a replaced log starts over */
    close(fd);
    unlink(log);
    puts("DIAGNOSTICS PASS: three levels, play mode carries no debug env, stored level clamped, env round trip, lock-timeout trigger");
  }
}

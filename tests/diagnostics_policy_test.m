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
    assert([env[@"WINEIOS_METAL_DEBUG"] isEqualToString:@"1"]);
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
    puts("DIAGNOSTICS PASS: three levels, play mode carries no debug env, stored level clamped, env round trip");
  }
}

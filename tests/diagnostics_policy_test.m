#import "../src/ios/diagnostics.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
  @autoreleasepool {
    IOSWineDiagPolicy off = IOSWineDiagPolicyFor(IOSWineDiagOff);
    assert(off.heartbeat_seconds == 30 && !off.mach_exc_monitor && !off.thread_dumps && !off.guest_sampler);
    assert(!off.log_snapshot && !off.boot_probes);
    assert(!strcmp(off.winedebug_steam, "-all,err+all"));
    assert(IOSWineDiagLaunchEnv(IOSWineDiagOff).count == 0);

    IOSWineDiagPolicy basic = IOSWineDiagPolicyFor(IOSWineDiagBasic);
    assert(basic.heartbeat_seconds == 10 && basic.guest_sampler && !basic.mach_exc_monitor && !basic.thread_dumps);
    assert(!IOSWineDiagLaunchEnv(IOSWineDiagBasic)[@"IOSWINE_THREAD_DUMP"]);

    IOSWineDiagPolicy full = IOSWineDiagPolicyFor(IOSWineDiagFull);
    assert(full.heartbeat_seconds == 5 && full.fine_first_ticks && full.mach_exc_monitor && full.thread_dumps && full.log_snapshot);
    assert(strstr(full.winedebug_steam, "trace+loaddll") && !strstr(full.winedebug_steam, "seh"));
    assert(strstr(full.winedebug_other, "trace+seh"));
    NSDictionary *env = IOSWineDiagLaunchEnv(IOSWineDiagFull);
    assert([env[@"IOSWINE_THREAD_DUMP"] isEqualToString:@"5"]);
    assert([env[@"WINEIOS_METAL_DEBUG"] isEqualToString:@"1"]);
    assert([env[@"IOSWINE_XINPUT_TRACE"] isEqualToString:@"1"]);

    unsetenv("IOSWINE_DIAG_LEVEL");
    assert(IOSWineDiagLevelFromEnv() == IOSWineDiagOff);
    setenv("IOSWINE_DIAG_LEVEL", "1", 1);
    assert(IOSWineDiagLevelFromEnv() == IOSWineDiagBasic);
    setenv("IOSWINE_DIAG_LEVEL", "9", 1);
    assert(IOSWineDiagLevelFromEnv() == IOSWineDiagFull);
    setenv("IOSWINE_DIAG_LEVEL", "-3", 1);
    assert(IOSWineDiagLevelFromEnv() == IOSWineDiagOff);

    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:@"ioswine-diag-test"];
    [ud removePersistentDomainForName:@"ioswine-diag-test"];
    assert(IOSWineDiagLevelStored(ud) == IOSWineDiagOff);
    IOSWineDiagStore(ud, IOSWineDiagBasic);
    assert(IOSWineDiagLevelStored(ud) == IOSWineDiagBasic);
    [ud setInteger:7 forKey:@"ioswine.diag.level"];
    assert(IOSWineDiagLevelStored(ud) == IOSWineDiagFull);
    IOSWineDiagStore(ud, IOSWineDiagBasic);
    unsetenv("IOSWINE_DIAG_LEVEL");
    assert(IOSWineDiagApplyToEnvironment(ud) == IOSWineDiagBasic);
    assert(!strcmp(getenv("IOSWINE_DIAG_LEVEL"), "1"));
    IOSWineDiagStore(ud, IOSWineDiagFull);
    assert(IOSWineDiagApplyToEnvironment(ud) == IOSWineDiagFull && IOSWineDiagLevelFromEnv() == IOSWineDiagFull);
    IOSWineDiagStore(ud, IOSWineDiagOff);
    assert(IOSWineDiagApplyToEnvironment(ud) == IOSWineDiagOff && IOSWineDiagLevelFromEnv() == IOSWineDiagOff);
    [ud removePersistentDomainForName:@"ioswine-diag-test"];
    puts("DIAGNOSTICS PASS: three levels, play mode carries no debug env, stored level clamped, env round trip");
  }
}

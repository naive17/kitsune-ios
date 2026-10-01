#import "../src/ios/process_monitor.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static KitsuneProcessInfo Proc(unsigned pid, unsigned ppid, unsigned flags, unsigned long long cpu_us, const char *name) {
  KitsuneProcessInfo p;
  memset(&p, 0, sizeof(p));
  p.pid = pid;
  p.ppid = ppid;
  p.threads = 3;
  p.flags = flags;
  p.cpu_us = cpu_us;
  p.age_ticks = 754 * 10000000ULL;
  strncpy(p.name, name, sizeof(p.name) - 1);
  return p;
}

static NSArray *Column(NSArray<NSDictionary *> *rows, NSString *key) {
  NSMutableArray *out = [NSMutableArray array];
  for (NSDictionary *r in rows) [out addObject:r[key] ?: NSNull.null];
  return out;
}

int main(void) {
  @autoreleasepool {
    assert(KitsuneCPUPercent(1500000, @1000000, 2.0) == 25.0);
    assert(KitsuneCPUPercent(5000000, @1000000, 2.0) == 200.0);   /* two cores busy */
    assert(KitsuneCPUPercent(1000, nil, 2.0) == -1);
    assert(KitsuneCPUPercent(1000, @2000, 2.0) == -1);            /* reused pid */
    assert(KitsuneCPUPercent(1000, @0, 0) == -1);
    assert([KitsuneUptimeText(42) isEqualToString:@"0:42"]);
    assert([KitsuneUptimeText(725) isEqualToString:@"12:05"]);
    assert([KitsuneUptimeText(3729) isEqualToString:@"1:02:09"]);
    assert([KitsuneUptimeText(-3) isEqualToString:@"0:00"]);

    /* The session host, an ordinary process to the server, started Steam;
     * Steam started the helper and the game; services.exe is Wine's own. */
    KitsuneProcessInfo procs[] = {
      Proc(0x20, 0, 0, 100, "kitsune-session.exe"),
      Proc(0x30, 0x20, KITSUNE_PROCESS_SYSTEM, 0, "services.exe"),
      Proc(0x50, 0x20, 0, 4000000, "steam.exe"),
      Proc(0x90, 0x50, KITSUNE_PROCESS_TERMINATING, 900000, "steamwebhelper.exe"),
      Proc(0x70, 0x50, 0, 2000000, "DarkSoulsRemastered.exe"),
      Proc(0xa0, 0, 0, 0, ""),
    };
    int n = (int)(sizeof(procs) / sizeof(procs[0]));
    NSArray *windows = @[
      @{@"hwnd": @0x1001, @"pid": @0x70, @"tid": @0x74, @"title": @"DARK SOULS"},
      @{@"hwnd": @0x1002, @"pid": @0x50, @"tid": @0x54, @"title": @"Steam"},
      @{@"hwnd": @0x1003, @"pid": @0x400, @"tid": @0x404, @"title": @"Gone"},
    ];
    NSDictionary *prev = @{@0x50: @3000000, @0x70: @500000, @0x90: @2000000};

    NSArray<NSDictionary *> *rows = KitsuneProcessRows(procs, n, NO, windows, prev, 2.0);
    assert(([Column(rows, @"kind") isEqual:@[@"process", @"window", @"process", @"window", @"process", @"process", @"window"]]));
    assert(([Column(rows, @"depth") isEqual:@[@0, @1, @1, @2, @1, @0, @0]]));
    assert(([[rows[0] objectForKey:@"name"] isEqualToString:@"steam.exe"]));
    assert(([[rows[1] objectForKey:@"title"] isEqualToString:@"Steam"]));
    assert(([[rows[2] objectForKey:@"name"] isEqualToString:@"DarkSoulsRemastered.exe"]));
    assert(([[rows[4] objectForKey:@"name"] isEqualToString:@"steamwebhelper.exe"]));
    assert(([[rows[5] objectForKey:@"name"] isEqualToString:@"pid 160"]));   /* nameless */
    assert(([[rows[6] objectForKey:@"title"] isEqualToString:@"Gone"]));     /* owner not listed */
    assert([rows[0][@"cpu"] doubleValue] == 50.0);
    assert([rows[2][@"cpu"] doubleValue] == 75.0);
    assert([rows[4][@"cpu"] doubleValue] == -1);                           /* counter went backwards */
    assert([rows[5][@"cpu"] doubleValue] == -1);                           /* no earlier sample */
    assert([rows[4][@"terminating"] boolValue] && ![rows[0][@"terminating"] boolValue]);
    assert([rows[0][@"uptime"] doubleValue] == 754.0);
    assert([rows[0][@"threads"] isEqual:@3] && [rows[2][@"ppid"] isEqual:@0x50]);

    NSArray<NSDictionary *> *sys = KitsuneProcessRows(procs, n, YES, windows, prev, 2.0);
    assert(([Column(sys, @"name") isEqual:@[@"kitsune-session.exe", @"services.exe"]]));
    assert(([Column(sys, @"depth") isEqual:@[@0, @1]]));

    /* A parent cycle still lists both processes once. */
    KitsuneProcessInfo cycle[] = { Proc(8, 12, 0, 0, "a.exe"), Proc(12, 8, 0, 0, "b.exe") };
    NSArray<NSDictionary *> *crows = KitsuneProcessRows(cycle, 2, NO, @[], @{}, 2.0);
    assert(([Column(crows, @"name") isEqual:@[@"a.exe", @"b.exe"]]));
    assert(([Column(crows, @"depth") isEqual:@[@0, @1]]));

    NSDictionary *times = KitsuneProcessCPUTimes(procs, n);
    assert(times.count == 6 && [times[@0x50] isEqual:@4000000]);
    assert(KitsuneProcessRows(procs, 0, NO, @[], nil, 0).count == 0);
    puts("process_monitor_test: ok");
  }
  return 0;
}

/*
 * The process monitor's model.
 *
 * The in-process wineserver lists every Windows process with a live thread
 * (wineserver_inproc_process_snapshot in server/process.c): its pid, parent,
 * thread count, CPU time and age. Two snapshots a few seconds apart give each
 * process's CPU use; the driver's window list hangs each window under the
 * process that owns it. Memory is not split by process: every process lives
 * in the app's one address space, so only the app's total means anything.
 */
#ifndef KITSUNE_PROCESS_MONITOR_H
#define KITSUNE_PROCESS_MONITOR_H

#import <Foundation/Foundation.h>
#include <string.h>

/* Same layout as struct kitsune_process_info in server/process.c. */
typedef struct {
  unsigned pid, ppid, threads;
  unsigned flags;                 /* KITSUNE_PROCESS_* */
  unsigned long long cpu_us;      /* user + system time of its live threads */
  unsigned long long age_ticks;   /* since it started, in 100 ns */
  char name[64];                  /* exe file name, UTF-8 */
} KitsuneProcessInfo;

enum { KITSUNE_PROCESS_SYSTEM = 1, KITSUNE_PROCESS_TERMINATING = 2 };

/* Wine's own, whatever the server says: the session host (src/session) is an
 * ordinary process to Wine, but ending it ends every program. */
static inline BOOL KitsuneProcessIsWine(const KitsuneProcessInfo *p) {
  return (p->flags & KITSUNE_PROCESS_SYSTEM) || !strncmp(p->name, "kitsune-session.exe", sizeof(p->name));
}

/* CPU use in percent of one core (Activity Monitor's scale: a process busy on
 * two cores shows 200), or -1 without an earlier sample to compare with. A
 * counter that went backwards is a new process with a reused pid. */
static inline double KitsuneCPUPercent(unsigned long long now_us, NSNumber *prev_us, double elapsed) {
  if (!prev_us || elapsed <= 0 || now_us < prev_us.unsignedLongLongValue) return -1;
  return (double)(now_us - prev_us.unsignedLongLongValue) / (elapsed * 1e6) * 100.0;
}

/* "0:42", "12:05", "1:02:09". */
static inline NSString *KitsuneUptimeText(double seconds) {
  long s = seconds > 0 ? (long)seconds : 0;
  if (s >= 3600) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", s / 3600, s / 60 % 60, s % 60];
  return [NSString stringWithFormat:@"%ld:%02ld", s / 60, s % 60];
}

/* The rows of one section, programs (`system` NO) or Wine's own processes
 * (KitsuneProcessIsWine), in tree order: each process, then its windows, then
 * its children. A parent counts only when it is in the same section, so
 * programs the session host started are roots. Process rows: kind "process", pid, ppid, name, threads,
 * depth, uptime (seconds), terminating, cpu (percent, -1 when unknown).
 * Window rows: kind "window", depth, and the window's own keys from
 * WineTasksSnapshot (hwnd, pid, tid, title). Windows of a process that is not
 * in the snapshot go last in the programs section. `prev` maps pid to cpu_us
 * of the snapshot taken `elapsed` seconds earlier. */
static inline NSArray<NSDictionary *> *KitsuneProcessRows(const KitsuneProcessInfo *procs, int count, BOOL system,
                                                          NSArray<NSDictionary *> *windows,
                                                          NSDictionary<NSNumber *, NSNumber *> *prev,
                                                          double elapsed) {
  NSMutableDictionary<NSNumber *, NSValue *> *byPid = [NSMutableDictionary dictionary];
  NSMutableArray<NSNumber *> *allPids = [NSMutableArray array];
  for (int i = 0; i < count; i++)
    if (KitsuneProcessIsWine(&procs[i]) == system) {
      byPid[@(procs[i].pid)] = [NSValue valueWithPointer:&procs[i]];
      [allPids addObject:@(procs[i].pid)];
    }
  [allPids sortUsingSelector:@selector(compare:)];

  NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *children = [NSMutableDictionary dictionary];
  NSMutableArray<NSNumber *> *roots = [NSMutableArray array];
  for (NSNumber *pid in allPids) {
    const KitsuneProcessInfo *p = byPid[pid].pointerValue;
    if (p->ppid != p->pid && byPid[@(p->ppid)]) {
      if (!children[@(p->ppid)]) children[@(p->ppid)] = [NSMutableArray array];
      [children[@(p->ppid)] addObject:pid];
    } else {
      [roots addObject:pid];
    }
  }

  NSMutableDictionary<NSNumber *, NSMutableArray<NSDictionary *> *> *windowsByPid = [NSMutableDictionary dictionary];
  NSMutableArray<NSDictionary *> *orphans = [NSMutableArray array];
  for (NSDictionary *w in windows) {
    NSNumber *pid = w[@"pid"];
    if (pid && byPid[pid]) {
      if (!windowsByPid[pid]) windowsByPid[pid] = [NSMutableArray array];
      [windowsByPid[pid] addObject:w];
    } else if (!system) {
      [orphans addObject:w];
    }
  }

  NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
  NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
  __block void (^__weak weakVisit)(NSNumber *, NSInteger);
  void (^visit)(NSNumber *, NSInteger) = ^(NSNumber *pid, NSInteger depth) {
    if ([seen containsObject:pid]) return;
    [seen addObject:pid];
    const KitsuneProcessInfo *p = byPid[pid].pointerValue;
    NSString *name = [[NSString alloc] initWithBytes:p->name length:strnlen(p->name, sizeof(p->name))
                                            encoding:NSUTF8StringEncoding];
    [rows addObject:@{
      @"kind": @"process",
      @"pid": pid,
      @"ppid": @(p->ppid),
      @"name": name.length ? name : [NSString stringWithFormat:@"pid %u", p->pid],
      @"threads": @(p->threads),
      @"depth": @(depth),
      @"uptime": @((double)p->age_ticks / 1e7),
      @"terminating": @((p->flags & KITSUNE_PROCESS_TERMINATING) != 0),
      @"cpu": @(KitsuneCPUPercent(p->cpu_us, prev[pid], elapsed)),
    }];
    for (NSDictionary *w in windowsByPid[pid]) {
      NSMutableDictionary *row = [w mutableCopy];
      row[@"kind"] = @"window";
      row[@"depth"] = @(depth + 1);
      [rows addObject:row];
    }
    for (NSNumber *child in children[pid]) weakVisit(child, depth + 1);
  };
  weakVisit = visit;
  for (NSNumber *pid in roots) visit(pid, 0);
  /* A parent cycle leaves processes no root reaches. */
  for (NSNumber *pid in allPids) visit(pid, 0);
  for (NSDictionary *w in orphans) {
    NSMutableDictionary *row = [w mutableCopy];
    row[@"kind"] = @"window";
    row[@"depth"] = @0;
    [rows addObject:row];
  }
  return rows;
}

/* pid -> cpu_us of a snapshot, the `prev` of the next KitsuneProcessRows. */
static inline NSDictionary<NSNumber *, NSNumber *> *KitsuneProcessCPUTimes(const KitsuneProcessInfo *procs, int count) {
  NSMutableDictionary<NSNumber *, NSNumber *> *times = [NSMutableDictionary dictionaryWithCapacity:(NSUInteger)count];
  for (int i = 0; i < count; i++) times[@(procs[i].pid)] = @(procs[i].cpu_us);
  return times;
}

#endif

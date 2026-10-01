#import "task_manager.h"
#import "power.h"
#import "process_monitor.h"
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include <mach/mach.h>
#include <os/proc.h>
#include <pthread.h>

NSNotificationName const WineTasksDidUpdateNotification = @"WineTasksDidUpdate";

static void (*drv_request)(void);
static void (*drv_close)(void *);
static void (*drv_kill)(unsigned);
static pthread_mutex_t tasks_lock = PTHREAD_MUTEX_INITIALIZER;
static NSArray<NSDictionary *> *tasks_snapshot;

__attribute__((visibility("default")))
void wine_surface_host_register_tasks(void *request, void *close, void *kill) {
  drv_request = request;
  drv_close = close;
  drv_kill = kill;
}

__attribute__((visibility("default")))
void wine_surface_host_tasks_report(const WineTask *tasks, unsigned count) {
  NSMutableArray *list = [NSMutableArray arrayWithCapacity:count];
  for (unsigned i = 0; i < count; i++) {
    NSString *title = [NSString stringWithUTF8String:tasks[i].title] ?: @"?";
    [list addObject:@{
      @"hwnd": @((uintptr_t)tasks[i].hwnd),
      @"pid": @(tasks[i].pid),
      @"tid": @(tasks[i].tid),
      @"title": title,
    }];
  }
  pthread_mutex_lock(&tasks_lock);
  tasks_snapshot = list;
  pthread_mutex_unlock(&tasks_lock);
  dispatch_async(dispatch_get_main_queue(), ^{
    [NSNotificationCenter.defaultCenter postNotificationName:WineTasksDidUpdateNotification object:nil];
  });
}

BOOL WineTasksAvailable(void) { return drv_request != NULL; }
void WineTasksRequest(void) { if (drv_request) drv_request(); }
void WineTasksClose(void *hwnd) { if (drv_close) drv_close(hwnd); }
void WineTasksKill(unsigned pid) { if (drv_kill) drv_kill(pid); }

NSArray<NSDictionary *> *WineTasksSnapshot(void) {
  pthread_mutex_lock(&tasks_lock);
  NSArray *list = tasks_snapshot ?: @[];
  pthread_mutex_unlock(&tasks_lock);
  return list;
}

/* Every Windows process with a live thread, from the in-process server. */
extern int wineserver_inproc_process_snapshot(KitsuneProcessInfo *out, int max);

/* CPU time of the whole app: its live threads plus those that have ended. */
static unsigned long long app_cpu_us(void) {
  mach_task_basic_info_data_t basic;
  task_thread_times_info_data_t live;
  mach_msg_type_number_t n = MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&basic, &n) != KERN_SUCCESS) return 0;
  n = TASK_THREAD_TIMES_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_THREAD_TIMES_INFO, (task_info_t)&live, &n) != KERN_SUCCESS) return 0;
  return (unsigned long long)(basic.user_time.seconds + basic.system_time.seconds + live.user_time.seconds +
                              live.system_time.seconds) * 1000000ULL +
         (unsigned long long)(basic.user_time.microseconds + basic.system_time.microseconds +
                              live.user_time.microseconds + live.system_time.microseconds);
}

static unsigned long long footprint_bytes(void) {
  task_vm_info_data_t info;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
  return info.phys_footprint;
}

/* One reading of everything the monitor shows. */
@interface KitsuneMonitorSample : NSObject
@property(nonatomic) NSData *procs;             /* KitsuneProcessInfo[] */
@property(nonatomic) double time;
@property(nonatomic) unsigned long long appCPU, footprint, available, metal;
@end
@implementation KitsuneMonitorSample
@end

static NSString *Bytes(unsigned long long b) {
  return b >= (1ULL << 30) ? [NSString stringWithFormat:@"%.2f GB", b / 1073741824.0]
                           : [NSString stringWithFormat:@"%llu MB", b >> 20];
}

static NSString *Percent(double p) {
  return p < 0 ? @"–" : [NSString stringWithFormat:@"%.0f%%", p];
}

enum { SecSummary, SecPrograms, SecWine, SecCount };
enum { SumMemory, SumGraphics, SumCPU, SumHost, SumThermal, SumPower, SumCount };

@implementation WineTaskListVC {
  NSArray<NSDictionary *> *_programs, *_wine;
  KitsuneMonitorSample *_sample;
  NSDictionary<NSNumber *, NSNumber *> *_prevTimes;
  unsigned long long _prevAppCPU;
  double _elapsed;
  NSTimer *_timer;
  dispatch_queue_t _queue;
  BOOL _swiping;
}

- (instancetype)init {
  if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
    self.title = NSLocalizedString(@"Processes", nil);
    _queue = dispatch_queue_create("kitsune.process-monitor", DISPATCH_QUEUE_SERIAL);
    _programs = _wine = @[];
  }
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.navigationItem.rightBarButtonItem =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                    target:self action:@selector(onDone)];
  self.navigationItem.leftBarButtonItem =
      [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Quit all", nil) style:UIBarButtonItemStylePlain
                                       target:self action:@selector(onQuitAll)];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(rebuild)
                                             name:WineTasksDidUpdateNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self refresh];
  __weak WineTaskListVC *weakSelf = self;
  _timer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t __unused) {
    [weakSelf refresh];
  }];
}

- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  [_timer invalidate];
  _timer = nil;
}

- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self];
}

/* The server snapshot takes the server's lock, so it is read off the main
 * thread; the window list comes back through the driver. */
- (void)refresh {
  WineTasksRequest();
  __weak WineTaskListVC *weakSelf = self;
  dispatch_async(_queue, ^{
    static id<MTLDevice> device;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ device = MTLCreateSystemDefaultDevice(); });
    KitsuneMonitorSample *s = [KitsuneMonitorSample new];
    NSMutableData *procs = [NSMutableData dataWithLength:256 * sizeof(KitsuneProcessInfo)];
    int n = wineserver_inproc_process_snapshot(procs.mutableBytes, 256);
    procs.length = (NSUInteger)(n > 0 ? n : 0) * sizeof(KitsuneProcessInfo);
    s.procs = procs;
    s.time = CACurrentMediaTime();
    s.appCPU = app_cpu_us();
    s.footprint = footprint_bytes();
    s.available = os_proc_available_memory();
    s.metal = device.currentAllocatedSize;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf take:s]; });
  });
}

- (void)take:(KitsuneMonitorSample *)s {
  if (_sample) {
    _prevTimes = KitsuneProcessCPUTimes(_sample.procs.bytes, (int)(_sample.procs.length / sizeof(KitsuneProcessInfo)));
    _prevAppCPU = _sample.appCPU;
    _elapsed = s.time - _sample.time;
  }
  _sample = s;
  [self rebuild];
}

- (void)rebuild {
  const KitsuneProcessInfo *procs = _sample.procs.bytes;
  int n = (int)(_sample.procs.length / sizeof(KitsuneProcessInfo));
  NSArray *windows = WineTasksSnapshot();
  _programs = KitsuneProcessRows(procs, n, NO, windows, _prevTimes, _elapsed);
  _wine = KitsuneProcessRows(procs, n, YES, windows, _prevTimes, _elapsed);
  /* A reload closes an open swipe, so it waits until the swipe is done. */
  if (!_swiping) [self.tableView reloadData];
}

- (void)onDone {
  [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)onQuitAll {
  for (NSDictionary *t in WineTasksSnapshot()) WineTasksClose((void *)[t[@"hwnd"] unsignedLongValue]);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{ WineTasksRequest(); });
}

- (NSArray<NSDictionary *> *)rowsIn:(NSInteger)section {
  return section == SecPrograms ? _programs : section == SecWine ? _wine : nil;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)t {
  return SecCount;
}

- (NSInteger)tableView:(UITableView *__unused)t numberOfRowsInSection:(NSInteger)s {
  return s == SecSummary ? SumCount : (NSInteger)[self rowsIn:s].count;
}

- (NSString *)tableView:(UITableView *__unused)t titleForHeaderInSection:(NSInteger)s {
  switch (s) {
  case SecSummary: return @"Kitsune";
  case SecPrograms: return NSLocalizedString(@"Programs", nil);
  default: return NSLocalizedString(@"Wine", nil);
  }
}

- (NSString *)tableView:(UITableView *__unused)t titleForFooterInSection:(NSInteger)s {
  switch (s) {
  case SecSummary:
    return NSLocalizedString(@"CPU is per core: 100% is one core busy. Every program shares the app's memory, so it is counted once, here.", nil);
  case SecPrograms:
    return _programs.count ? NSLocalizedString(@"Swipe a program to end it, or a window to close it.", nil)
                           : NSLocalizedString(@"Nothing is running.", nil);
  default:
    return _wine.count ? NSLocalizedString(@"Wine's own processes. Ending one can stop every program.", nil) : nil;
  }
}

- (UITableViewCell *)summaryCell:(UITableView *)t row:(NSInteger)row {
  UITableViewCell *cell = [t dequeueReusableCellWithIdentifier:@"summary"];
  if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"summary"];
  cell.selectionStyle = UITableViewCellSelectionStyleNone;
  cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
  KitsuneMonitorSample *s = _sample;
  double appCPU = s && _prevAppCPU ? KitsuneCPUPercent(s.appCPU, @(_prevAppCPU), _elapsed) : -1;
  switch (row) {
  case SumMemory:
    cell.textLabel.text = NSLocalizedString(@"Memory", nil);
    cell.detailTextLabel.text = s ? [NSString stringWithFormat:NSLocalizedString(@"%@ used · %@ free", nil),
                                     Bytes(s.footprint), Bytes(s.available)] : @"–";
    if (s && s.available < (256ULL << 20)) cell.detailTextLabel.textColor = UIColor.systemRedColor;
    else if (s && s.available < (512ULL << 20)) cell.detailTextLabel.textColor = UIColor.systemOrangeColor;
    break;
  case SumGraphics:
    cell.textLabel.text = NSLocalizedString(@"Graphics memory", nil);
    cell.detailTextLabel.text = s ? Bytes(s.metal) : @"–";
    break;
  case SumCPU:
    cell.textLabel.text = NSLocalizedString(@"CPU", nil);
    cell.detailTextLabel.text = [NSString stringWithFormat:NSLocalizedString(@"%@ of %ld%%", nil), Percent(appCPU),
                                 (long)NSProcessInfo.processInfo.activeProcessorCount * 100];
    break;
  case SumHost: {
    /* What no Windows process accounts for: drawing, audio, input and the
     * Wine server, all threads of the app itself. */
    double programs = 0;
    for (NSDictionary *r in [_programs arrayByAddingObjectsFromArray:_wine])
      if ([r[@"kind"] isEqualToString:@"process"] && [r[@"cpu"] doubleValue] > 0) programs += [r[@"cpu"] doubleValue];
    cell.textLabel.text = NSLocalizedString(@"Graphics, audio and server", nil);
    cell.detailTextLabel.text = Percent(appCPU < 0 ? -1 : MAX(0.0, appCPU - programs));
    break;
  }
  case SumThermal: {
    NSProcessInfoThermalState th = NSProcessInfo.processInfo.thermalState;
    cell.textLabel.text = NSLocalizedString(@"Temperature", nil);
    cell.detailTextLabel.text = th == NSProcessInfoThermalStateNominal ? NSLocalizedString(@"Normal", nil)
                              : th == NSProcessInfoThermalStateFair ? NSLocalizedString(@"Warm", nil)
                              : th == NSProcessInfoThermalStateSerious ? NSLocalizedString(@"Hot · iOS is slowing the phone", nil)
                              : NSLocalizedString(@"Very hot · iOS is slowing the phone", nil);
    if (th >= NSProcessInfoThermalStateSerious) cell.detailTextLabel.textColor = UIColor.systemOrangeColor;
    break;
  }
  default: {
    WinePowerMode mode = WinePower.shared.effectiveMode;
    cell.textLabel.text = NSLocalizedString(@"Power Mode", nil);
    cell.detailTextLabel.text = mode == WinePowerPerformance ? NSLocalizedString(@"Performance", nil)
                              : mode == WinePowerBattery
                                  ? [NSString stringWithFormat:NSLocalizedString(@"Battery · 30 fps cap (%@)", nil),
                                     WinePower.shared.batteryReason ?: @""]
                                  : NSLocalizedString(@"Balanced", nil);
    if (mode == WinePowerBattery) cell.detailTextLabel.textColor = UIColor.systemGreenColor;
    break;
  }
  }
  return cell;
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
  if (ip.section == SecSummary) return [self summaryCell:t row:ip.row];
  NSDictionary *row = [self rowsIn:ip.section][(NSUInteger)ip.row];
  UITableViewCell *cell = [t dequeueReusableCellWithIdentifier:@"row"];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"row"];
    cell.indentationWidth = 18;
    UILabel *cpu = [UILabel new];
    cpu.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular];
    cpu.textAlignment = NSTextAlignmentRight;
    cpu.frame = CGRectMake(0, 0, 56, 24);
    cell.accessoryView = cpu;
  }
  cell.selectionStyle = UITableViewCellSelectionStyleNone;
  cell.indentationLevel = [row[@"depth"] integerValue];
  cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
  UILabel *cpu = (UILabel *)cell.accessoryView;
  if ([row[@"kind"] isEqualToString:@"window"]) {
    cell.imageView.image = [UIImage systemImageNamed:@"macwindow"];
    cell.textLabel.text = row[@"title"];
    cell.detailTextLabel.text = [NSString stringWithFormat:NSLocalizedString(@"window %#lx", nil),
                                 [row[@"hwnd"] unsignedLongValue]];
    cpu.text = nil;
    return cell;
  }
  cell.imageView.image = [UIImage systemImageNamed:ip.section == SecWine ? @"gearshape" : @"app"];
  cell.textLabel.text = row[@"name"];
  NSString *detail = [NSString stringWithFormat:NSLocalizedString(@"pid %@ · %@ threads · up %@", nil), row[@"pid"],
                      row[@"threads"], KitsuneUptimeText([row[@"uptime"] doubleValue])];
  if ([row[@"terminating"] boolValue]) {
    detail = [detail stringByAppendingString:NSLocalizedString(@" · ending", nil)];
    cell.detailTextLabel.textColor = UIColor.systemOrangeColor;
  }
  cell.detailTextLabel.text = detail;
  double p = [row[@"cpu"] doubleValue];
  cpu.text = Percent(p);
  cpu.textColor = p >= 90 ? UIColor.systemOrangeColor : UIColor.labelColor;
  return cell;
}

- (void)tableView:(UITableView *__unused)t willBeginEditingRowAtIndexPath:(NSIndexPath *__unused)ip {
  _swiping = YES;
}

- (void)tableView:(UITableView *)t didEndEditingRowAtIndexPath:(NSIndexPath *__unused)ip {
  _swiping = NO;
  [t reloadData];
}

- (void)confirm:(NSString *)title message:(NSString *)message action:(NSString *)action then:(void (^)(void))then {
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
                                                          preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
  [alert addAction:[UIAlertAction actionWithTitle:action style:UIAlertActionStyleDestructive
                                          handler:^(UIAlertAction *x __unused) { then(); }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *__unused)t
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
  if (ip.section == SecSummary) return nil;
  NSDictionary *row = [self rowsIn:ip.section][(NSUInteger)ip.row];
  __weak WineTaskListVC *weakSelf = self;
  unsigned pid = [row[@"pid"] unsignedIntValue];
  if ([row[@"kind"] isEqualToString:@"window"]) {
    UIContextualAction *close = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal title:NSLocalizedString(@"Close", nil)
                          handler:^(UIContextualAction *a __unused, UIView *v __unused, void (^done)(BOOL)) {
      WineTasksClose((void *)[row[@"hwnd"] unsignedLongValue]);
      done(YES);
    }];
    close.backgroundColor = UIColor.systemOrangeColor;
    UIContextualAction *kill = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive title:NSLocalizedString(@"Force Quit", nil)
                          handler:^(UIContextualAction *a __unused, UIView *v __unused, void (^done)(BOOL)) {
      [weakSelf confirm:[NSString stringWithFormat:NSLocalizedString(@"Force Quit %@?", nil), row[@"title"]]
                message:NSLocalizedString(@"Unsaved progress is lost.", nil)
                 action:NSLocalizedString(@"Force Quit", nil)
                   then:^{ WineTasksKill(pid); }];
      done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[ kill, close ]];
  }
  BOOL wine = ip.section == SecWine;
  UIContextualAction *end = [UIContextualAction
      contextualActionWithStyle:UIContextualActionStyleDestructive title:NSLocalizedString(@"End", nil)
                        handler:^(UIContextualAction *a __unused, UIView *v __unused, void (^done)(BOOL)) {
    [weakSelf confirm:[NSString stringWithFormat:NSLocalizedString(@"End %@?", nil), row[@"name"]]
              message:wine ? NSLocalizedString(@"Wine needs this process. Ending it can stop every program, and unsaved progress is lost.", nil)
                           : NSLocalizedString(@"Unsaved progress is lost. Processes it started keep running.", nil)
               action:NSLocalizedString(@"End", nil)
                 then:^{ WineTasksKill(pid); }];
    done(YES);
  }];
  return [UISwipeActionsConfiguration configurationWithActions:@[ end ]];
}

@end

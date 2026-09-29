#import "task_manager.h"

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

@implementation WineTaskListVC {
  NSArray<NSDictionary *> *_tasks;
  NSTimer *_timer;
}

- (instancetype)init {
  if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
    self.title = NSLocalizedString(@"Running", nil);
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
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(onUpdate)
                                             name:WineTasksDidUpdateNotification object:nil];
  _tasks = WineTasksSnapshot();
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  WineTasksRequest();
  _timer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t __unused) {
    WineTasksRequest();
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

- (void)onUpdate {
  _tasks = WineTasksSnapshot();
  [self.tableView reloadData];
}

- (void)onDone {
  [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)onQuitAll {
  for (NSDictionary *t in _tasks) WineTasksClose((void *)[t[@"hwnd"] unsignedLongValue]);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{ WineTasksRequest(); });
}

- (NSInteger)tableView:(UITableView *__unused)t numberOfRowsInSection:(NSInteger __unused)s {
  return (NSInteger)_tasks.count;
}

- (NSString *)tableView:(UITableView *__unused)t titleForFooterInSection:(NSInteger __unused)s {
  if (!WineTasksAvailable()) return NSLocalizedString(@"No windows yet.", nil);
  return _tasks.count ? NSLocalizedString(@"Swipe left to close or force quit.", nil)
                      : NSLocalizedString(@"No windows yet.", nil);
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
  UITableViewCell *cell = [t dequeueReusableCellWithIdentifier:@"task"];
  if (!cell)
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"task"];
  NSDictionary *task = _tasks[(NSUInteger)ip.row];
  cell.textLabel.text = task[@"title"];
  cell.detailTextLabel.text = [NSString stringWithFormat:NSLocalizedString(@"pid %@ · window %#lx", nil),
                               task[@"pid"], [task[@"hwnd"] unsignedLongValue]];
  cell.selectionStyle = UITableViewCellSelectionStyleNone;
  return cell;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *__unused)t
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
  NSDictionary *task = _tasks[(NSUInteger)ip.row];
  UIContextualAction *close = [UIContextualAction
      contextualActionWithStyle:UIContextualActionStyleNormal title:NSLocalizedString(@"Close", nil)
                        handler:^(UIContextualAction *a __unused, UIView *v __unused, void (^done)(BOOL)) {
    WineTasksClose((void *)[task[@"hwnd"] unsignedLongValue]);
    done(YES);
  }];
  close.backgroundColor = UIColor.systemOrangeColor;
  UIContextualAction *kill = [UIContextualAction
      contextualActionWithStyle:UIContextualActionStyleDestructive title:NSLocalizedString(@"Force Quit", nil)
                        handler:^(UIContextualAction *a __unused, UIView *v __unused, void (^done)(BOOL)) {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:NSLocalizedString(@"Force Quit %@?", nil), task[@"title"]]
                         message:NSLocalizedString(@"Unsaved progress is lost.", nil)
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Force Quit", nil) style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *x __unused) {
      WineTasksKill([task[@"pid"] unsignedIntValue]);
    }]];
    [self presentViewController:alert animated:YES completion:nil];
    done(YES);
  }];
  return [UISwipeActionsConfiguration configurationWithActions:@[ kill, close ]];
}

@end

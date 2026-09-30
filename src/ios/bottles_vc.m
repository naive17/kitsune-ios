#import "bottles_vc.h"

#import "launcher_vc.h"
#include "app_library.h"
#include "boot_status.h"
#include "bottles.h"
#include "reset.h"
#include "steam_library.h"
#include "wine_boot.h"
#include "wine_command.h"

static NSString *HumanSize(unsigned long long bytes) {
  if (bytes >= 1ull << 30) return [NSString stringWithFormat:NSLocalizedString(@"%.1f GB", nil), (double)bytes / (double)(1ull << 30)];
  return [NSString stringWithFormat:NSLocalizedString(@"%llu MB", nil), bytes >> 20];
}

/* Bottles being created, duplicated or deleted, by name, with what is being
 * done to them. The work runs in the background and the list shows it on the
 * bottle's row; only a failure interrupts, with an alert. Main thread. */
static NSMutableDictionary<NSString *, NSString *> *BusyBottles(void) {
  static NSMutableDictionary *busy;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ busy = [NSMutableDictionary dictionary]; });
  return busy;
}

static NSString *const WineBusyBottlesDidChangeNotification = @"WineBusyBottlesDidChange";

/* `work` runs off the main thread and returns NO with *error set when it fails. */
static void RunBottleWork(NSString *name, NSString *stage, WineLauncherVC *host, NSString *failure,
                          BOOL (^work)(NSString **error)) {
  BusyBottles()[name] = stage;
  [NSNotificationCenter.defaultCenter postNotificationName:WineBusyBottlesDidChangeNotification object:nil];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSString *err = nil;
    BOOL ok = work(&err);
    dispatch_async(dispatch_get_main_queue(), ^{
      [BusyBottles() removeObjectForKey:name];
      [NSNotificationCenter.defaultCenter postNotificationName:WineBusyBottlesDidChangeNotification object:nil];
      if (!ok) [host report:failure message:err ?: NSLocalizedString(@"unknown error", nil)];
    });
  });
}

@implementation WineBottlesVC {
  WineStatusHeader *_header;
  NSArray<NSString *> *_bottles;
  NSDictionary<NSString *, NSNumber *> *_sizes;
  NSDictionary<NSString *, NSNumber *> *_programs;
}

- (instancetype)init {
  if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) self.title = NSLocalizedString(@"Bottles", nil);
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.navigationItem.rightBarButtonItem =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(onNew)];
  _header = [[WineStatusHeader alloc] initWithFrame:CGRectMake(0, 0, 320, 56)];
  self.tableView.tableHeaderView = _header;
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(onStatus)
                                             name:WineBootStatusDidChangeNotification object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh)
                                             name:WineBusyBottlesDidChangeNotification object:nil];
  [self refresh];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self refresh];
}

- (void)onStatus {
  [_header update];
  [self layoutHeader];
}

- (void)layoutHeader {
  CGFloat h = _header.hidden ? 0 : [_header systemLayoutSizeFittingSize:CGSizeMake(self.tableView.bounds.size.width - 32, 0)
                                                     withHorizontalFittingPriority:UILayoutPriorityRequired
                                                           verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
  _header.frame = CGRectMake(16, 0, self.tableView.bounds.size.width - 32, h);
  self.tableView.tableHeaderView = _header;
}

- (void)refresh {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSString *docs = KitsunePersistentDocuments();
    NSArray *names = KitsuneBottleNames(docs);
    NSMutableDictionary *sizes = [NSMutableDictionary dictionary], *programs = [NSMutableDictionary dictionary];
    for (NSString *n in names) {
      sizes[n] = @(KitsuneDirectorySize(KitsuneBottlePath(docs, n)));
      NSUInteger count = 0;
      for (WineApp *a in WineAppLibrary.shared.apps)
        if ([(a.bottle ?: KITSUNE_DEFAULT_BOTTLE) isEqualToString:n]) count++;
      if ([n isEqualToString:@"Steam"] && KitsuneSteamRoot(docs)) count += KitsuneSteamGames(KitsuneSteamRoot(docs)).count;
      programs[n] = @(count);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      /* A bottle being created has no directory yet. */
      NSMutableArray *all = [names mutableCopy];
      for (NSString *n in [BusyBottles().allKeys sortedArrayUsingSelector:@selector(compare:)])
        if (![all containsObject:n]) [all addObject:n];
      self->_bottles = all;
      self->_sizes = sizes;
      self->_programs = programs;
      [self layoutHeader];
      [self.tableView reloadData];
    });
  });
}

- (void)onNew {
  UIAlertController *a = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"New Bottle", nil) message:NSLocalizedString(@"Letters, digits, - or _.", nil)
                                                      preferredStyle:UIAlertControllerStyleAlert];
  [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
    f.placeholder = NSLocalizedString(@"name", nil);
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
  }];
  [a addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
  [a addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Create", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *x __unused) {
    NSString *name = a.textFields.firstObject.text;
    WineLauncherVC *host = (WineLauncherVC *)self.tabBarController;
    NSString *err = nil;
    if (BusyBottles()[name] || !KitsuneBottleNameFree(KitsunePersistentDocuments(), name, &err)) {
      [host report:NSLocalizedString(@"Can't Create", nil) message:err ?: [NSString stringWithFormat:NSLocalizedString(@"A bottle named %@ already exists.", nil), name]];
      return;
    }
    RunBottleWork(name, NSLocalizedString(@"Creating…", nil), host, NSLocalizedString(@"Can't Create", nil), ^BOOL(NSString **error) {
      return KitsuneCreateBottle(KitsunePersistentDocuments(), WineTreeRoot(), name, error);
    });
  }]];
  [self presentViewController:a animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *__unused)t numberOfRowsInSection:(NSInteger __unused)s { return (NSInteger)_bottles.count; }

- (NSString *)tableView:(UITableView *__unused)t titleForFooterInSection:(NSInteger __unused)s {
  return _bottles.count ? NSLocalizedString(@"Each bottle is a separate Windows installation.", nil) : NSLocalizedString(@"No bottles yet.", nil);
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
  UITableViewCell *cell = [t dequeueReusableCellWithIdentifier:@"bottle"] ?:
      [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"bottle"];
  NSString *name = _bottles[(NSUInteger)ip.row];
  NSUInteger n = _programs[name].unsignedIntegerValue;
  NSString *busy = BusyBottles()[name];
  cell.imageView.image = [UIImage systemImageNamed:[name isEqualToString:@"Steam"] ? @"cloud" : @"shippingbox"];
  cell.textLabel.text = name;
  if (busy) {
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [spinner startAnimating];
    cell.detailTextLabel.text = busy;
    cell.accessoryView = spinner;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
  } else {
    cell.detailTextLabel.text = [NSString stringWithFormat:NSLocalizedString(@"%@ · %lu program%@", nil), HumanSize(_sizes[name].unsignedLongLongValue), (unsigned long)n, n == 1 ? @"" : @"s"];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
  }
  return cell;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
  [t deselectRowAtIndexPath:ip animated:YES];
  NSString *name = _bottles[(NSUInteger)ip.row];
  if (BusyBottles()[name]) return;
  [self.navigationController pushViewController:[[WineBottleDetailVC alloc] initWithBottle:name] animated:YES];
}

@end

/* --- detail ------------------------------------------------------------ */

typedef NS_ENUM(NSInteger, BottleSection) { BottleAbout = 0, BottlePrograms, BottleTools, BottleDelete, BottleSectionCount };

@implementation WineBottleDetailVC {
  NSString *_name;
  NSArray<NSString *> *_facts;
  NSArray<NSDictionary *> *_programs;   /* name plus "app" (WineApp) or "steam" (app id, empty for the client) */
}

- (instancetype)initWithBottle:(NSString *)name {
  if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
    _name = [name copy];
    self.title = name;
  }
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
  [self installMenu];
  [self load];
}

- (WineLauncherVC *)host { return (WineLauncherVC *)self.tabBarController; }

/* Duplicate for every bottle; Rename only for the user's own, since the app
 * finds the default bottle and Steam's by name. */
- (void)installMenu {
  __weak WineBottleDetailVC *weakSelf = self;
  NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
  [items addObject:[UIAction actionWithTitle:NSLocalizedString(@"Duplicate…", nil) image:[UIImage systemImageNamed:@"plus.square.on.square"]
                                  identifier:nil handler:^(UIAction *a __unused) { [weakSelf askName:NO]; }]];
  if (![_name isEqualToString:KITSUNE_DEFAULT_BOTTLE] && ![_name isEqualToString:@"Steam"])
    [items addObject:[UIAction actionWithTitle:NSLocalizedString(@"Rename…", nil) image:[UIImage systemImageNamed:@"pencil"]
                                    identifier:nil handler:^(UIAction *a __unused) { [weakSelf askName:YES]; }]];
  self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                                                                              menu:[UIMenu menuWithChildren:items]];
}

- (void)askName:(BOOL)rename {
  NSString *verb = rename ? NSLocalizedString(@"Rename", nil) : NSLocalizedString(@"Duplicate", nil);
  UIAlertController *a = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"%@ %@", verb, _name]
                                                             message:NSLocalizedString(@"Letters, digits, - or _.", nil)
                                                      preferredStyle:UIAlertControllerStyleAlert];
  [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
    f.text = rename ? self->_name : [self->_name stringByAppendingString:@"-copy"];
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
  }];
  [a addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
  [a addAction:[UIAlertAction actionWithTitle:verb style:UIAlertActionStyleDefault handler:^(UIAlertAction *x __unused) {
    NSString *to = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (rename) [self renameTo:to];
    else [self duplicateTo:to];
  }]];
  [self presentViewController:a animated:YES completion:nil];
}

- (void)renameTo:(NSString *)to {
  NSString *err = nil;
  if (!KitsuneRenameBottle(KitsunePersistentDocuments(), _name, to, &err)) {
    [self.host report:NSLocalizedString(@"Can't Rename", nil) message:err];
    return;
  }
  for (WineApp *app in WineAppLibrary.shared.apps)
    if ([app.bottle isEqualToString:_name]) app.bottle = to;
  [WineAppLibrary.shared save];
  _name = [to copy];
  self.title = to;
  [self installMenu];
  [self load];
}

/* The copy shows up in the list, which this returns to. */
- (void)duplicateTo:(NSString *)to {
  NSString *from = _name;
  NSString *err = nil;
  if (BusyBottles()[to] || !KitsuneBottleNameFree(KitsunePersistentDocuments(), to, &err)) {
    [self.host report:NSLocalizedString(@"Can't Duplicate", nil) message:err ?: [NSString stringWithFormat:NSLocalizedString(@"A bottle named %@ already exists.", nil), to]];
    return;
  }
  RunBottleWork(to, NSLocalizedString(@"Duplicating…", nil), self.host, NSLocalizedString(@"Can't Duplicate", nil), ^BOOL(NSString **error) {
    return KitsuneDuplicateBottle(KitsunePersistentDocuments(), from, to, error);
  });
  [self.navigationController popViewControllerAnimated:YES];
}

- (NSString *)driveC {
  return [KitsuneBottlePath(KitsunePersistentDocuments(), _name) stringByAppendingPathComponent:@"drive_c"];
}

- (void)load {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSString *docs = KitsunePersistentDocuments();
    NSString *path = KitsuneBottlePath(docs, self->_name);
    NSMutableArray *facts = [NSMutableArray array], *programs = [NSMutableArray array];
    [facts addObject:[NSString stringWithFormat:NSLocalizedString(@"Size: %@", nil), HumanSize(KitsuneDirectorySize(path))]];
    NSString *stamp = [[NSString stringWithContentsOfFile:[path stringByAppendingPathComponent:@".tree-stamp"] encoding:NSUTF8StringEncoding error:nil]
                       stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    [facts addObject:[NSString stringWithFormat:NSLocalizedString(@"Runtime: %@", nil), stamp.length ? stamp : NSLocalizedString(@"unknown", nil)]];
    [facts addObject:[NSString stringWithFormat:NSLocalizedString(@"Path: %@", nil), [path stringByReplacingOccurrencesOfString:docs withString:@"Documents"]]];
    for (WineApp *a in WineAppLibrary.shared.apps)
      if (a.origin != WineAppOriginBuiltin && [(a.bottle ?: KITSUNE_DEFAULT_BOTTLE) isEqualToString:self->_name])
        [programs addObject:@{ @"name": a.name, @"app": a }];
    if ([self->_name isEqualToString:@"Steam"] && KitsuneSteamRoot(docs)) {
      [programs addObject:@{ @"name": NSLocalizedString(@"Steam", nil), @"steam": @"" }];
      for (NSDictionary *g in KitsuneSteamGames(KitsuneSteamRoot(docs)))
        [programs addObject:@{ @"name": g[@"name"], @"steam": g[@"appid"] }];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      self->_facts = facts;
      self->_programs = programs;
      [self.tableView reloadData];
    });
  });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)t { return BottleSectionCount; }

- (NSInteger)tableView:(UITableView *__unused)t numberOfRowsInSection:(NSInteger)s {
  switch (s) {
  case BottleAbout: return (NSInteger)_facts.count;
  case BottlePrograms: return (NSInteger)MAX(_programs.count, 1u);
  case BottleTools: return (NSInteger)KITSUNE_BOTTLE_TOOL_COUNT + 1;
  default: return 1;
  }
}

- (NSString *)tableView:(UITableView *__unused)t titleForHeaderInSection:(NSInteger)s {
  if (s == BottlePrograms) return NSLocalizedString(@"Programs", nil);
  if (s == BottleTools) return NSLocalizedString(@"Tools", nil);
  return nil;
}

- (NSString *)tableView:(UITableView *__unused)t titleForFooterInSection:(NSInteger)s {
  if (s != BottleDelete) return nil;
  if ([_name isEqualToString:KITSUNE_DEFAULT_BOTTLE]) return NSLocalizedString(@"Deleting resets it to a fresh bottle.", nil);
  if ([_name isEqualToString:@"Steam"]) return NSLocalizedString(@"Deletes Steam, your games and their saves.", nil);
  return NSLocalizedString(@"Deletes everything installed in it.", nil);
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
  UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
  cell.textLabel.numberOfLines = 2;
  cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
  cell.selectionStyle = UITableViewCellSelectionStyleDefault;
  switch (ip.section) {
  case BottleAbout:
    cell.textLabel.text = _facts[(NSUInteger)ip.row];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    break;
  case BottlePrograms:
    if (!_programs.count) {
      cell.textLabel.text = NSLocalizedString(@"No programs", nil);
      cell.textLabel.textColor = UIColor.tertiaryLabelColor;
      cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
      NSDictionary *p = _programs[(NSUInteger)ip.row];
      cell.textLabel.text = p[@"name"];
      cell.imageView.image = [UIImage systemImageNamed:p[@"steam"] ? @"gamecontroller" : @"app.badge"];
    }
    break;
  case BottleTools:
    if ((NSUInteger)ip.row < KITSUNE_BOTTLE_TOOL_COUNT) {
      const KitsuneBottleTool *tool = &kKitsuneBottleTools[ip.row];
      cell.textLabel.text = NSLocalizedString(@(tool->title), nil);
      cell.imageView.image = [UIImage systemImageNamed:@(tool->symbol)];
    } else {
      cell.textLabel.text = NSLocalizedString(@"Show Drive C in Files", nil);
      cell.imageView.image = [UIImage systemImageNamed:@"externaldrive"];
    }
    break;
  default:
    cell.textLabel.text = NSLocalizedString(@"Delete Bottle", nil);
    cell.textLabel.textColor = UIColor.systemRedColor;
    cell.textLabel.textAlignment = NSTextAlignmentCenter;
  }
  return cell;
}

- (void)runProgram:(NSDictionary *)p {
  WineLauncherVC *host = self.host;
  if (p[@"steam"]) {
    NSString *appID = [p[@"steam"] length] ? p[@"steam"] : nil;
    [host.launcherDelegate launcher:host playSteamApp:appID named:p[@"name"]];
    return;
  }
  WineApp *app = p[@"app"];
  BOOL gui = YES;
  NSString *pe = [WineTreeRoot() stringByAppendingPathComponent:@"lib/wine/aarch64-windows"];
  NSArray<NSString *> *argv = KitsuneProgramArgv(app.exePath, app.arguments, app.subsystem == PE_SUBSYSTEM_CONSOLE, pe, &gui);
  [host.launcherDelegate launcher:host runArgv:argv workingDir:app.workingDir bottle:_name gui:gui label:app.name];
}

- (void)runTool:(const KitsuneBottleTool *)tool {
  WineLauncherVC *host = self.host;
  NSString *pe = [WineTreeRoot() stringByAppendingPathComponent:@"lib/wine/aarch64-windows"];
  [host.launcherDelegate launcher:host runArgv:KitsuneToolArgv(tool, pe) workingDir:[self driveC]
                           bottle:_name gui:YES label:NSLocalizedString(@(tool->title), nil)];
}

- (void)showInFiles {
  NSString *path = [[self driveC] stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
  NSURL *url = [NSURL URLWithString:[@"shareddocuments://" stringByAppendingString:path]];
  [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL opened) {
    if (opened) return;
    NSString *app = NSBundle.mainBundle.infoDictionary[@"CFBundleDisplayName"] ?: NSBundle.mainBundle.infoDictionary[@"CFBundleName"];
    NSString *docs = KitsunePersistentDocuments();
    NSArray<NSString *> *parts = [[[self driveC] substringFromIndex:docs.length] pathComponents];
    NSPredicate *named = [NSPredicate predicateWithFormat:@"SELF != '/'"];
    NSString *where = [[@[ NSLocalizedString(@"On My iPhone", nil), app ] arrayByAddingObjectsFromArray:[parts filteredArrayUsingPredicate:named]]
                       componentsJoinedByString:@" > "];
    [self.host report:NSLocalizedString(@"Open in Files", nil) message:where];
  }];
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
  [t deselectRowAtIndexPath:ip animated:YES];
  if (ip.section == BottlePrograms && _programs.count) { [self runProgram:_programs[(NSUInteger)ip.row]]; return; }
  if (ip.section == BottleTools) {
    if ((NSUInteger)ip.row < KITSUNE_BOTTLE_TOOL_COUNT) [self runTool:&kKitsuneBottleTools[ip.row]];
    else [self showInFiles];
    return;
  }
  if (ip.section != BottleDelete) return;
  BOOL steam = [_name isEqualToString:@"Steam"];
  UIAlertController *a = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:NSLocalizedString(@"Delete %@?", nil), _name]
      message:steam ? NSLocalizedString(@"This deletes Steam, your games and their saves. Type “delete” to confirm.", nil)
                    : NSLocalizedString(@"Everything installed in it is removed.", nil)
      preferredStyle:UIAlertControllerStyleAlert];
  if (steam) [a addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = NSLocalizedString(@"delete", nil); f.autocapitalizationType = UITextAutocapitalizationTypeNone; }];
  [a addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
  [a addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Delete", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x __unused) {
    if (steam && ![a.textFields.firstObject.text isEqualToString:NSLocalizedString(@"delete", nil)]) return;
    NSString *name = self->_name;
    BOOL reset = [name isEqualToString:KITSUNE_DEFAULT_BOTTLE];
    RunBottleWork(name, reset ? NSLocalizedString(@"Resetting…", nil) : NSLocalizedString(@"Deleting…", nil), self.host,
                  reset ? NSLocalizedString(@"Can't Reset", nil) : NSLocalizedString(@"Can't Delete", nil), ^BOOL(NSString **error) {
      NSString *docs = KitsunePersistentDocuments();
      NSError *e = nil;
      BOOL ok;
      if (reset) {
        ok = [NSFileManager.defaultManager removeItemAtPath:KitsuneBottlePath(docs, nil) error:&e];
        if (!ok) *error = e.localizedDescription;
        else ok = KitsuneCreateDefaultPrefix(docs, WineTreeRoot(), error);
      }
      else if (steam) {
        ok = [NSFileManager.defaultManager removeItemAtPath:KitsuneBottlePath(docs, @"Steam") error:&e];
        if (!ok) *error = e.localizedDescription;
        [NSFileManager.defaultManager removeItemAtPath:[docs stringByAppendingPathComponent:@"Apps/Steam"] error:nil];
      } else
        ok = KitsuneDeleteBottle(docs, name, error);
      for (WineApp *app in WineAppLibrary.shared.apps)
        if ([app.bottle isEqualToString:name]) app.bottle = nil;
      [WineAppLibrary.shared save];
      return ok;
    });
    [self.navigationController popViewControllerAnimated:YES];
  }]];
  [self presentViewController:a animated:YES completion:nil];
}

@end

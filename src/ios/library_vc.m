#import "library_vc.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "launcher_vc.h"
#import "program_icons.h"
#import "progress_vc.h"
#import "steam_install_vc.h"
#include "app_library.h"
#include "boot_status.h"
#include "bottles.h"
#include "launcher_settings.h"
#include "runtime_tree.h"
#include "steam_install.h"
#include "steam_library.h"
#include "wine_boot.h"
#include "wine_command.h"

typedef NS_ENUM(NSInteger, LibrarySection) {
  SectionSteam = 0,
  SectionImported,
  SectionInstalled,
  SectionBuiltin,
  SectionCount,
};

static BOOL HaveWow64(void) {
  BOOL isDir = NO;
  NSString *dir = [WineTreeRoot() stringByAppendingPathComponent:@"lib/wine/i386-windows"];
  return [NSFileManager.defaultManager fileExistsAtPath:dir isDirectory:&isDir] && isDir;
}

static NSString *HumanSize(unsigned long long bytes) {
  if (bytes >= 1ull << 30) return [NSString stringWithFormat:NSLocalizedString(@"%.1f GB", nil), (double)bytes / (double)(1ull << 30)];
  if (bytes >= 1ull << 20) return [NSString stringWithFormat:NSLocalizedString(@"%llu MB", nil), bytes >> 20];
  return @"";
}

@interface WineLibraryVC () <UIDocumentPickerDelegate, UISearchResultsUpdating>
@end

@implementation WineLibraryVC {
  WineStatusHeader *_header;
  NSArray<WineApp *> *_imported, *_installed, *_builtin;
  NSArray<NSDictionary *> *_steamGames;
  NSArray<WineApp *> *_allImported, *_allInstalled, *_allBuiltin;   /* before the search filter */
  NSArray<NSDictionary *> *_allSteamGames;
  NSString *_query;
  NSArray<NSString *> *_bottles;
  NSString *_steamRoot;
  BOOL _haveWow64;
  BOOL _iconReloadPending;
}

- (instancetype)init {
  if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) self.title = NSLocalizedString(@"Library", nil);
  return self;
}

- (WineLauncherVC *)host { return (WineLauncherVC *)self.tabBarController; }

- (BOOL)ready {
  WineBootPhase phase = WineBootStatus.shared.phase;
  return phase == WineBootPhaseReady || phase == WineBootPhaseNeedsJIT || phase == WineBootPhaseRunning;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.navigationItem.rightBarButtonItem =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(onImport)];
  UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
  search.searchResultsUpdater = self;
  search.obscuresBackgroundDuringPresentation = NO;
  search.searchBar.placeholder = NSLocalizedString(@"Search programs and games", nil);
  self.navigationItem.searchController = search;
  self.definesPresentationContext = YES;
  _header = [[WineStatusHeader alloc] initWithFrame:CGRectMake(0, 0, 320, 56)];
  self.tableView.tableHeaderView = _header;
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(onStatus)
                                             name:WineBootStatusDidChangeNotification object:nil];
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
  [self.tableView reloadData];
}

- (void)layoutHeader {
  CGFloat h = _header.hidden ? 0 : [_header systemLayoutSizeFittingSize:CGSizeMake(self.tableView.bounds.size.width - 32, 0)
                                                     withHorizontalFittingPriority:UILayoutPriorityRequired
                                                           verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
  _header.frame = CGRectMake(16, 0, self.tableView.bounds.size.width - 32, h);
  self.tableView.tableHeaderView = _header;
}

/* Disk work off the main thread; the table reloads when the lists arrive. */
- (void)refresh {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSString *docs = IOSWinePersistentDocuments();
    NSString *steam = IOSWineSteamRoot(docs);
    NSArray *games = steam ? IOSWineSteamGames(steam) : @[];
    NSArray *bottles = IOSWineBottleNames(docs);
    BOOL wow = HaveWow64();
    NSArray *apps = WineAppLibrary.shared.apps;
    NSPredicate *(^by)(WineAppOrigin) = ^(WineAppOrigin o) {
      return [NSPredicate predicateWithBlock:^BOOL(WineApp *a, NSDictionary *b __unused) { return a.origin == o; }];
    };
    NSArray *imported = [apps filteredArrayUsingPredicate:by(WineAppOriginImported)];
    NSArray *installed = [apps filteredArrayUsingPredicate:by(WineAppOriginInstalled)];
    NSArray *builtin = [apps filteredArrayUsingPredicate:by(WineAppOriginBuiltin)];
    dispatch_async(dispatch_get_main_queue(), ^{
      self->_steamRoot = steam;
      self->_allSteamGames = games;
      self->_bottles = bottles;
      self->_haveWow64 = wow;
      self->_allImported = imported;
      self->_allInstalled = installed;
      self->_allBuiltin = builtin;
      [self applyFilter];
      [self layoutHeader];
      [self.tableView reloadData];
    });
  });
}

/* --- import ----------------------------------------------------------- */

- (void)onImport {
  NSMutableArray<UTType *> *types = [NSMutableArray array];
  for (NSString *ext in @[ @"exe", @"msi" ]) {
    UTType *t = [UTType typeWithFilenameExtension:ext];
    if (t) [types addObject:t];
  }
  [types addObject:UTTypeZIP];
  UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
  p.delegate = self;
  p.allowsMultipleSelection = NO;
  [self presentViewController:p animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *__unused)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
  NSURL *url = urls.firstObject;
  if (!url) return;
  WineProgressVC *progress = [WineProgressVC presentFrom:self title:[NSLocalizedString(@"Importing ", nil) stringByAppendingString:url.lastPathComponent]];
  [progress setStage:NSLocalizedString(@"Importing…", nil) detail:nil fraction:-1];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSString *err = nil;
    NSArray<WineApp *> *added = [WineAppLibrary.shared importFileAtURL:url progress:^(NSString *line) {
      dispatch_async(dispatch_get_main_queue(), ^{ [progress setStage:line detail:nil fraction:-1]; });
    } error:&err];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!added) [progress failWithMessage:err ?: NSLocalizedString(@"Import failed", nil)];
      else [progress finish];
      [self refresh];
    });
  });
}

/* --- Steam ------------------------------------------------------------ */

- (void)onInstallSteam {
  if (WineSteamInstaller.isRunning) return;
  if (!IOSWineTreeVersion(WineTreeRoot()).length) {
    [self.host report:NSLocalizedString(@"Enable JIT First", nil) message:NSLocalizedString(@"Steam can be installed once JIT is on.", nil)];
    return;
  }
  [WineSteamInstallVC presentFrom:self onInstalled:^{ [self refresh]; }];
}

/* --- search ----------------------------------------------------------- */

- (void)updateSearchResultsForSearchController:(UISearchController *)controller {
  _query = [controller.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  [self applyFilter];
  [self.tableView reloadData];
}

- (void)applyFilter {
  NSString *q = _query;
  NSPredicate *byName = [NSPredicate predicateWithBlock:^BOOL(id item, NSDictionary *b __unused) {
    NSString *name = [item isKindOfClass:NSDictionary.class] ? item[@"name"] : ((WineApp *)item).name;
    return !q.length || [name localizedCaseInsensitiveContainsString:q];
  }];
  _imported = [_allImported filteredArrayUsingPredicate:byName];
  _installed = [_allInstalled filteredArrayUsingPredicate:byName];
  _builtin = [_allBuiltin filteredArrayUsingPredicate:byName];
  _steamGames = [_allSteamGames filteredArrayUsingPredicate:byName];
}

/* --- table ------------------------------------------------------------ */

- (NSArray<WineApp *> *)appsForSection:(NSInteger)s {
  switch (s) {
  case SectionImported: return _imported ?: @[];
  case SectionInstalled: return _installed ?: @[];
  case SectionBuiltin: return _builtin ?: @[];
  default: return @[];
  }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)t { return SectionCount; }

- (NSInteger)tableView:(UITableView *__unused)t numberOfRowsInSection:(NSInteger)s {
  if (s == SectionSteam) return _steamRoot ? (NSInteger)_steamGames.count + 1 : 1;
  return (NSInteger)[self appsForSection:s].count;
}

- (NSString *)tableView:(UITableView *__unused)t titleForHeaderInSection:(NSInteger)s {
  switch (s) {
  case SectionSteam: return NSLocalizedString(@"Steam", nil);
  case SectionImported: return _imported.count ? NSLocalizedString(@"My programs", nil) : nil;
  case SectionInstalled: return _installed.count ? NSLocalizedString(@"Installed by programs", nil) : nil;
  case SectionBuiltin: return _builtin.count ? NSLocalizedString(@"Included with Wine", nil) : nil;
  default: return nil;
  }
}

- (NSString *)tableView:(UITableView *__unused)t titleForFooterInSection:(NSInteger)s {
  if (_query.length) return nil;
  if (s == SectionSteam && _steamRoot && !_steamGames.count)
    return NSLocalizedString(@"Games you install in Steam appear here.", nil);
  if (s == SectionImported && !_imported.count)
    return NSLocalizedString(@"Tap + to add a portable ZIP, an .exe or an installer.", nil);
  return nil;
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
  UITableViewCell *cell = [t dequeueReusableCellWithIdentifier:@"row"] ?:
      [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"row"];
  cell.textLabel.textColor = UIColor.labelColor;
  cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
  cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  cell.selectionStyle = UITableViewCellSelectionStyleDefault;
  cell.imageView.image = nil;

  if (ip.section == SectionSteam) {
    if (!_steamRoot) {
      BOOL busy = WineSteamInstaller.isRunning;
      cell.imageView.image = [UIImage systemImageNamed:@"arrow.down.circle"];
      cell.textLabel.text = busy ? NSLocalizedString(@"Installing Steam…", nil) : NSLocalizedString(@"Install Steam", nil);
      cell.detailTextLabel.text = busy ? NSLocalizedString(@"in progress", nil) : NSLocalizedString(@"Valve's client, downloaded into this app", nil);
      cell.accessoryType = UITableViewCellAccessoryNone;
      return cell;
    }
    if ((NSUInteger)ip.row < _steamGames.count) {
      NSDictionary *g = _steamGames[(NSUInteger)ip.row];
      BOOL installed = [g[@"installed"] boolValue];
      NSString *size = HumanSize([g[@"size"] unsignedLongLongValue]);
      cell.imageView.image = [WineIcons.shared artForSteamApp:g[@"appid"] steamRoot:_steamRoot ready:^{ [self iconsLoaded]; }]
                             ?: [UIImage systemImageNamed:@"gamecontroller"];
      cell.textLabel.text = g[@"name"];
      cell.textLabel.textColor = installed ? UIColor.labelColor : UIColor.tertiaryLabelColor;
      cell.detailTextLabel.text = installed ? [NSString stringWithFormat:NSLocalizedString(@"Steam · %@", nil), size.length ? size : g[@"appid"]]
                                            : NSLocalizedString(@"Downloading in Steam", nil);
      return cell;
    }
    NSString *steamExe = [_steamRoot stringByAppendingPathComponent:@"steam.exe"];
    cell.imageView.image = [WineIcons.shared iconForExecutable:steamExe ready:^{ [self iconsLoaded]; }]
                           ?: [UIImage systemImageNamed:@"cloud"];
    cell.textLabel.text = NSLocalizedString(@"Steam", nil);
    cell.detailTextLabel.text = nil;
    return cell;
  }

  WineApp *app = [self appsForSection:ip.section][(NSUInteger)ip.row];
  BOOL runnable = [app runnableWithWow64:_haveWow64];
  BOOL msi = [app.exePath.pathExtension.lowercaseString isEqualToString:@"msi"];
  UIImage *icon = msi ? nil : [WineIcons.shared iconForExecutable:app.exePath ready:^{ [self iconsLoaded]; }];
  cell.imageView.image = icon ?: [UIImage systemImageNamed:msi ? @"shippingbox"
                                                             : app.subsystem == PE_SUBSYSTEM_CONSOLE ? @"terminal" : @"app.badge"];
  cell.textLabel.text = app.name;
  cell.textLabel.textColor = runnable ? UIColor.labelColor : UIColor.tertiaryLabelColor;
  NSString *bottle = app.bottle ?: IOSWINE_DEFAULT_BOTTLE;
  if (msi)
    cell.detailTextLabel.text = [NSString stringWithFormat:NSLocalizedString(@"Installer · %@ bottle", nil), bottle];
  else if (!runnable)
    cell.detailTextLabel.text = app.arch == PE_ARCH_I386 ? NSLocalizedString(@"32-bit programs aren't supported yet", nil) : NSLocalizedString(@"Not supported", nil);
  else
    cell.detailTextLabel.text = [NSString stringWithFormat:NSLocalizedString(@"%@ · %@ bottle", nil), app.archLabel, bottle];
  return cell;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
  [t deselectRowAtIndexPath:ip animated:YES];
  if (ip.section == SectionSteam) {
    if (!_steamRoot) { if (![self ready]) [self notReady]; else [self onInstallSteam]; return; }
    if (![self ready]) { [self notReady]; return; }
    if ((NSUInteger)ip.row < _steamGames.count) {
      NSDictionary *g = _steamGames[(NSUInteger)ip.row];
      if (![g[@"installed"] boolValue]) return;
      [self confirmLaunch:g[@"name"] detail:nil action:^{
        [self.host.launcherDelegate launcher:self.host playSteamApp:g[@"appid"] named:g[@"name"]];
      }];
      return;
    }
    [self confirmLaunch:NSLocalizedString(@"Steam", nil) detail:nil action:^{
      [self.host.launcherDelegate launcher:self.host playSteamApp:nil named:NSLocalizedString(@"Steam", nil)];
    }];
    return;
  }
  WineApp *app = [self appsForSection:ip.section][(NSUInteger)ip.row];
  [self showProgram:app];
}

/* Icons arrive one by one; one reload covers all that land in the same turn. */
- (void)iconsLoaded {
  if (_iconReloadPending) return;
  _iconReloadPending = YES;
  dispatch_async(dispatch_get_main_queue(), ^{
    self->_iconReloadPending = NO;
    [self.tableView reloadData];
  });
}

- (void)notReady {
  [self.host report:NSLocalizedString(@"Not ready", nil) message:WineBootStatus.shared.message];
}

/* One confirmation before a launch; `detail` explains what follows, if anything. */
- (void)confirmLaunch:(NSString *)name detail:(NSString *)detail action:(void (^)(void))action {
  UIAlertController *a = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:NSLocalizedString(@"Run %@?", nil), name] message:detail
                                                      preferredStyle:UIAlertControllerStyleAlert];
  [a addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
  [a addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Run", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *x __unused) { action(); }]];
  [self presentViewController:a animated:YES completion:nil];
}

/* --- program sheet ---------------------------------------------------- */

- (void)showProgram:(WineApp *)app {
  BOOL isMSI = [app.exePath.pathExtension.lowercaseString isEqualToString:@"msi"];
  BOOL runnable = [app runnableWithWow64:_haveWow64];
  UIAlertController *a = [UIAlertController alertControllerWithTitle:app.name
      message:[NSString stringWithFormat:NSLocalizedString(@"%@\nBottle: %@%@", nil), app.archLabel, app.bottle ?: IOSWINE_DEFAULT_BOTTLE,
               app.arguments.length ? [NSLocalizedString(@"\nArguments: ", nil) stringByAppendingString:app.arguments] : @""]
      preferredStyle:UIAlertControllerStyleActionSheet];
  if (runnable && [self ready])
    [a addAction:[UIAlertAction actionWithTitle:isMSI ? NSLocalizedString(@"Install", nil) : NSLocalizedString(@"Run", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *x __unused) {
      /* Outside a session a console program is Wine's root process, and Wine
       * ends with it. */
      NSString *detail = !isMSI && app.subsystem == PE_SUBSYSTEM_CONSOLE
          ? NSLocalizedString(@"A console program runs on its own. Opening something else afterwards restarts ios-wine.", nil) : nil;
      [self confirmLaunch:app.name detail:detail action:^{ [self launch:app]; }];
    }]];
  if (!isMSI)
    [a addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Arguments…", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *x __unused) { [self editArguments:app]; }]];
  if (_bottles.count > 1)
    [a addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Bottle…", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *x __unused) { [self pickBottle:app]; }]];
  if (app.origin == WineAppOriginImported)
    [a addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Delete", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x __unused) { [self confirmDelete:app]; }]];
  [a addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
  a.popoverPresentationController.sourceView = self.view;
  [self presentViewController:a animated:YES completion:nil];
}

- (void)editArguments:(WineApp *)app {
  UIAlertController *a = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Arguments", nil) message:app.name preferredStyle:UIAlertControllerStyleAlert];
  [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
    f.placeholder = NSLocalizedString(@"Command-line arguments", nil);
    f.text = app.arguments ?: @"";
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
  }];
  [a addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
  [a addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Save", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *x __unused) {
    app.arguments = a.textFields.firstObject.text;
    [WineAppLibrary.shared save];
    [self.tableView reloadData];
  }]];
  [self presentViewController:a animated:YES completion:nil];
}

- (void)pickBottle:(WineApp *)app {
  UIAlertController *pick = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Choose Bottle", nil) message:nil
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
  for (NSString *name in _bottles)
    [pick addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction *y __unused) {
      app.bottle = [name isEqualToString:IOSWINE_DEFAULT_BOTTLE] ? nil : name;
      [WineAppLibrary.shared save];
      [self.tableView reloadData];
    }]];
  [pick addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
  pick.popoverPresentationController.sourceView = self.view;
  [self presentViewController:pick animated:YES completion:nil];
}

- (void)confirmDelete:(WineApp *)app {
  UIAlertController *a = [UIAlertController alertControllerWithTitle:[NSLocalizedString(@"Delete ", nil) stringByAppendingString:app.name]
                                                             message:NSLocalizedString(@"Its files are removed from this app.", nil)
                                                      preferredStyle:UIAlertControllerStyleAlert];
  [a addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
  [a addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Delete", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x __unused) {
    [WineAppLibrary.shared remove:app];
    [self refresh];
  }]];
  [self presentViewController:a animated:YES completion:nil];
}

- (void)launch:(WineApp *)app {
  BOOL gui = YES;
  NSString *pe = [WineTreeRoot() stringByAppendingPathComponent:@"lib/wine/aarch64-windows"];
  NSArray<NSString *> *argv = IOSWineProgramArgv(app.exePath, app.arguments, app.subsystem == PE_SUBSYSTEM_CONSOLE, pe, &gui);
  [self.host.launcherDelegate launcher:self.host runArgv:argv workingDir:app.workingDir bottle:app.bottle gui:gui label:app.name];
}

@end

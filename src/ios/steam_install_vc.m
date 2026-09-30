#import "steam_install_vc.h"

#include "steam_install.h"
#include "wine_boot.h"

static NSString *Bytes(unsigned long long n) {
  return [NSByteCountFormatter stringFromByteCount:(long long)n countStyle:NSByteCountFormatterCountStyleFile];
}

typedef NS_ENUM(NSInteger, SummaryRow) {
  RowClient,
  RowBottle,
  RowSetup,
  RowPackages,
  RowCount,
};

@class WineSteamPackagesVC;

@interface WineSteamInstallVC ()
@property(nonatomic, readonly) NSArray<NSDictionary *> *packages;
/* Package in progress: -1 before the first, count once all are in. */
@property(nonatomic, readonly) NSInteger current;
@property(nonatomic, readonly) WineSteamStep step;
@property(nonatomic, readonly) double fraction;
@property(nonatomic, readonly) BOOL installing;
@end

/* Every package: what it holds, its name and size, and how far it got. */
@interface WineSteamPackagesVC : UITableViewController
@property(nonatomic, weak) WineSteamInstallVC *install;
- (void)refreshRow:(NSInteger)row;
@end

@implementation WineSteamPackagesVC

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = NSLocalizedString(@"Packages", nil);
}

- (NSInteger)tableView:(UITableView *__unused)t numberOfRowsInSection:(NSInteger __unused)s {
  return (NSInteger)self.install.packages.count;
}

- (void)configure:(UITableViewCell *)cell row:(NSInteger)row {
  WineSteamInstallVC *install = self.install;
  NSDictionary *p = install.packages[(NSUInteger)row];
  cell.textLabel.text = p[@"title"];
  cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", p[@"name"], Bytes([p[@"downloadSize"] unsignedLongLongValue])];
  cell.accessoryType = row < install.current ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
  cell.accessoryView = nil;
  if (row == install.current && install.installing) {
    UILabel *state = [UILabel new];
    state.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
    state.textColor = UIColor.secondaryLabelColor;
    state.text = [NSString stringWithFormat:@"%.0f%%", install.fraction * 100];
    [state sizeToFit];
    cell.accessoryView = state;
  }
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
  UITableViewCell *cell = [t dequeueReusableCellWithIdentifier:@"package"] ?:
      [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"package"];
  cell.selectionStyle = UITableViewCellSelectionStyleNone;
  cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
  [self configure:cell row:ip.row];
  return cell;
}

- (void)refreshRow:(NSInteger)row {
  UITableViewCell *cell = row >= 0 ? [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]] : nil;
  if (cell) [self configure:cell row:row];
  else [self.tableView reloadData];
}

@end

@implementation WineSteamInstallVC {
  void (^_onInstalled)(void);
  NSString *_version;
  unsigned long long _total;
  UILabel *_status;
  UIProgressView *_bar;
  WineSteamPackagesVC *_list;
}

+ (void)presentFrom:(UIViewController *)host onInstalled:(void (^)(void))onInstalled {
  WineSteamInstallVC *vc = [[WineSteamInstallVC alloc] initWithStyle:UITableViewStyleInsetGrouped];
  vc->_onInstalled = [onInstalled copy];
  UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
  nav.modalPresentationStyle = UIModalPresentationPageSheet;
  [host presentViewController:nav animated:YES completion:nil];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = NSLocalizedString(@"Install Steam", nil);
  self.navigationItem.leftBarButtonItem =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(onCancel)];
  self.navigationItem.rightBarButtonItem =
      [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Install", nil) style:UIBarButtonItemStyleDone target:self action:@selector(onInstall)];

  _status = [UILabel new];
  _status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
  _status.numberOfLines = 0;
  _bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
  _bar.hidden = YES;
  UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:@[ _status, _bar ]];
  column.axis = UILayoutConstraintAxisVertical;
  column.spacing = 10;
  column.layoutMarginsRelativeArrangement = YES;
  column.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(16, 20, 20, 20);
  column.frame = CGRectMake(0, 0, self.view.bounds.size.width, 80);
  self.tableView.tableHeaderView = column;
  _current = -1;
  [self fetch];
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  UIView *header = self.tableView.tableHeaderView;
  CGFloat height = [header systemLayoutSizeFittingSize:CGSizeMake(self.tableView.bounds.size.width, 0)
                         withHorizontalFittingPriority:UILayoutPriorityRequired
                               verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
  if (fabs(header.frame.size.height - height) > 0.5) {
    header.frame = CGRectMake(0, 0, self.tableView.bounds.size.width, height);
    self.tableView.tableHeaderView = header;
  }
}

- (void)setStatus:(NSString *)text error:(BOOL)error {
  _status.text = text;
  _status.hidden = !text.length;   /* no gap above the bar for an empty line */
  _status.textColor = error ? UIColor.systemRedColor : UIColor.labelColor;
  [self.view setNeedsLayout];
}

- (void)fetch {
  [self setStatus:NSLocalizedString(@"Checking the latest version…", nil) error:NO];
  self.navigationItem.rightBarButtonItem.enabled = NO;
  [WineSteamInstaller fetchClientInto:KitsunePersistentDocuments()
                           completion:^(NSString *version, NSArray<NSDictionary *> *packages, NSString *error) {
    if (!packages) {
      [self setStatus:error error:YES];
      self.navigationItem.rightBarButtonItem.title = NSLocalizedString(@"Try Again", nil);
      self.navigationItem.rightBarButtonItem.action = @selector(fetch);
      self.navigationItem.rightBarButtonItem.enabled = YES;
      return;
    }
    self->_version = version;
    self->_packages = packages;
    self->_total = 0;
    for (NSDictionary *p in packages) self->_total += [p[@"downloadSize"] unsignedLongLongValue];
    [self setStatus:nil error:NO];
    self.navigationItem.rightBarButtonItem.title = NSLocalizedString(@"Install", nil);
    self.navigationItem.rightBarButtonItem.action = @selector(onInstall);
    self.navigationItem.rightBarButtonItem.enabled = YES;
    [self.tableView reloadData];
  }];
}

- (void)onInstall {
  _installing = YES;
  _current = -1;
  self.navigationController.modalInPresentation = YES;
  self.navigationItem.rightBarButtonItem.enabled = NO;
  _bar.hidden = NO;
  _bar.progress = 0;
  [_list.tableView reloadData];
  [WineSteamInstaller installIntoDocuments:KitsunePersistentDocuments() treeRoot:WineTreeRoot()
      progress:^(WineSteamStep step, NSUInteger package, double fraction, double overall) {
        [self step:step package:package fraction:fraction overall:overall];
      }
      completion:^(NSString *error) { [self finished:error]; }];
}

- (void)step:(WineSteamStep)step package:(NSUInteger)package fraction:(double)fraction overall:(double)overall {
  NSInteger previous = _current;
  _step = step;
  _fraction = fraction;
  [_bar setProgress:(float)overall animated:NO];
  switch (step) {
  case WineSteamStepPreparing:
    [self setStatus:NSLocalizedString(@"Preparing the Steam bottle…", nil) error:NO];
    return;
  case WineSteamStepFinishing:
    _current = (NSInteger)_packages.count;
    [self setStatus:NSLocalizedString(@"Finishing…", nil) error:NO];
    break;
  case WineSteamStepDownloading:
  case WineSteamStepUnpacking:
    if (package >= _packages.count) return;
    _current = (NSInteger)package;
    [self setStatus:[NSString stringWithFormat:step == WineSteamStepDownloading ? NSLocalizedString(@"Downloading %@…", nil) : NSLocalizedString(@"Unpacking %@…", nil),
                     _packages[package][@"title"]] error:NO];
    break;
  }
  if (_current == previous) [_list refreshRow:_current];
  else [_list.tableView reloadData];
}

- (void)finished:(NSString *)error {
  _installing = NO;
  self.navigationController.modalInPresentation = NO;
  self.navigationItem.leftBarButtonItem.enabled = YES;
  if (!error) {
    _current = (NSInteger)_packages.count;
    [_bar setProgress:1 animated:YES];
    [self setStatus:NSLocalizedString(@"Steam is installed.", nil) error:NO];
    self.navigationItem.leftBarButtonItem = nil;
    self.navigationItem.rightBarButtonItem.title = NSLocalizedString(@"Done", nil);
    self.navigationItem.rightBarButtonItem.action = @selector(onDone);
    self.navigationItem.rightBarButtonItem.enabled = YES;
    [_list.tableView reloadData];
    if (_onInstalled) _onInstalled();
    return;
  }
  BOOL cancelled = [error isEqualToString:@"Cancelled"];
  [self setStatus:cancelled ? NSLocalizedString(@"Stopped. Packages downloaded so far are kept.", nil) : error error:!cancelled];
  self.navigationItem.rightBarButtonItem.title = cancelled ? NSLocalizedString(@"Install", nil) : NSLocalizedString(@"Try Again", nil);
  self.navigationItem.rightBarButtonItem.enabled = YES;
  [_list.tableView reloadData];
}

- (void)onCancel {
  if (!_installing) { [self dismissViewControllerAnimated:YES completion:nil]; return; }
  self.navigationItem.leftBarButtonItem.enabled = NO;
  [self setStatus:NSLocalizedString(@"Stopping…", nil) error:NO];
  [WineSteamInstaller cancel];
}

- (void)onDone {
  [self dismissViewControllerAnimated:YES completion:nil];
}

/* --- summary ------------------------------------------------------------ */

- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)t {
  return _packages ? 1 : 0;
}

- (NSInteger)tableView:(UITableView *__unused)t numberOfRowsInSection:(NSInteger __unused)s {
  return RowCount;
}

- (NSString *)tableView:(UITableView *__unused)t titleForFooterInSection:(NSInteger __unused)s {
  /* Client versions are the build's Unix time. */
  NSDate *built = [NSDate dateWithTimeIntervalSince1970:_version.doubleValue];
  NSString *date = [NSDateFormatter localizedStringFromDate:built dateStyle:NSDateFormatterMediumStyle
                                                  timeStyle:NSDateFormatterNoStyle];
  return [NSString stringWithFormat:NSLocalizedString(@"Version %@, built %@. Each package is checked against Valve's checksums.", nil),
                                    _version, date];
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
  UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
  cell.selectionStyle = UITableViewCellSelectionStyleNone;
  cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
  cell.detailTextLabel.numberOfLines = 0;
  switch ((SummaryRow)ip.row) {
  case RowClient:
    cell.imageView.image = [UIImage systemImageNamed:@"arrow.down.circle"];
    cell.textLabel.text = NSLocalizedString(@"Steam for Windows", nil);
    cell.detailTextLabel.text = [NSString stringWithFormat:NSLocalizedString(@"%@ from Valve's update servers (client-update.akamai.steamstatic.com)", nil),
                                 Bytes(_total)];
    break;
  case RowBottle:
    cell.imageView.image = [UIImage systemImageNamed:@"shippingbox"];
    cell.textLabel.text = NSLocalizedString(@"Installs into the Steam bottle", nil);
    cell.detailTextLabel.text = NSLocalizedString(@"Created if it doesn't exist", nil);
    break;
  case RowSetup:
    cell.imageView.image = [UIImage systemImageNamed:@"gearshape"];
    cell.textLabel.text = NSLocalizedString(@"Also sets up", nil);
    cell.detailTextLabel.text = NSLocalizedString(@"Windows 10 mode, RSA crypto providers, Common Controls 6", nil);
    break;
  case RowPackages:
  case RowCount:
    cell.imageView.image = [UIImage systemImageNamed:@"list.bullet"];
    cell.textLabel.text = NSLocalizedString(@"Packages", nil);
    cell.detailTextLabel.text = [NSString stringWithFormat:NSLocalizedString(@"%lu, as Steam's own updater downloads them", nil), (unsigned long)_packages.count];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    break;
  }
  return cell;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
  [t deselectRowAtIndexPath:ip animated:YES];
  if (ip.row != RowPackages) return;
  if (!_list) {
    _list = [[WineSteamPackagesVC alloc] initWithStyle:UITableViewStyleInsetGrouped];
    _list.install = self;
  }
  [self.navigationController pushViewController:_list animated:YES];
}

@end

#import "launcher_vc.h"
#import "library_vc.h"
#import "bottles_vc.h"
#import "settings_vc.h"
#import "boot_status.h"

@implementation WineStatusHeader {
  UIActivityIndicatorView *_spinner;
  UILabel *_label;
  UIButton *_details;
  UIButton *_enableJIT;
  UIProgressView *_bar;
}

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.layer.cornerRadius = 12;
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.hidesWhenStopped = YES;
    _label = [UILabel new];
    _label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    _label.numberOfLines = 0;
    _details = [UIButton buttonWithType:UIButtonTypeSystem];
    [_details setTitle:NSLocalizedString(@"Details", nil) forState:UIControlStateNormal];
    [_details addTarget:self action:@selector(onDetails) forControlEvents:UIControlEventTouchUpInside];
    _enableJIT = [UIButton buttonWithType:UIButtonTypeSystem];
    [_enableJIT setTitle:NSLocalizedString(@"Enable JIT", nil) forState:UIControlStateNormal];
    _enableJIT.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [_enableJIT addTarget:self action:@selector(onEnableJIT) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ _spinner, _label, _enableJIT, _details ]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 10;
    row.alignment = UIStackViewAlignmentCenter;
    _bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _bar.hidden = YES;
    UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:@[ row, _bar ]];
    column.axis = UILayoutConstraintAxisVertical;
    column.spacing = 8;
    column.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:column];
    [NSLayoutConstraint activateConstraints:@[
      [column.topAnchor constraintEqualToAnchor:self.topAnchor constant:10],
      [column.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-10],
      [column.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
      [column.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
    ]];
    /* The message wraps; the buttons keep their full width. */
    [_label setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [_label setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    for (UIButton *b in @[ _enableJIT, _details ]) {
      [b setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
      [b setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    }
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(update)
                                               name:WineBootStatusDidChangeNotification object:nil];
    [self update];
  }
  return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)update {
  WineBootStatus *s = WineBootStatus.shared;
  BOOL busy = s.phase == WineBootPhasePreparing || s.phase == WineBootPhaseWaitingJIT || s.phase == WineBootPhaseLaunching;
  if (busy) [_spinner startAnimating]; else [_spinner stopAnimating];
  _label.text = s.message;
  _label.textColor = s.phase == WineBootPhaseFailed ? UIColor.systemRedColor : UIColor.labelColor;
  _enableJIT.hidden = (s.phase != WineBootPhaseNeedsJIT);
  _bar.hidden = s.progress < 0;
  if (s.progress >= 0) [_bar setProgress:(float)s.progress animated:YES];
  self.hidden = s.phase == WineBootPhaseReady || s.phase == WineBootPhaseRunning;
}

- (WineLauncherVC *)hostLauncher {
  UIResponder *r = self;
  while (r && ![r isKindOfClass:WineLauncherVC.class]) r = r.nextResponder;
  return (WineLauncherVC *)r;
}

- (void)onEnableJIT {
  WineLauncherVC *host = [self hostLauncher];
  [host.launcherDelegate launcherEnableJIT:host];
}

- (void)onDetails {
  WineLauncherVC *host = [self hostLauncher];
  [host.launcherDelegate launcherShowBootDetails:host];
}

@end

@implementation WineLauncherVC

- (void)viewDidLoad {
  [super viewDidLoad];
  WineLibraryVC *library = [WineLibraryVC new];
  WineBottlesVC *bottles = [WineBottlesVC new];
  WineSettingsVC *settings = [WineSettingsVC new];
  library.tabBarItem = [[UITabBarItem alloc] initWithTitle:NSLocalizedString(@"Library", nil) image:[UIImage systemImageNamed:@"square.grid.2x2"] tag:0];
  bottles.tabBarItem = [[UITabBarItem alloc] initWithTitle:NSLocalizedString(@"Bottles", nil) image:[UIImage systemImageNamed:@"shippingbox"] tag:1];
  settings.tabBarItem = [[UITabBarItem alloc] initWithTitle:NSLocalizedString(@"Settings", nil) image:[UIImage systemImageNamed:@"gearshape"] tag:2];
  NSMutableArray *navs = [NSMutableArray array];
  for (UIViewController *vc in @[ library, bottles, settings ]) {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.navigationBar.prefersLargeTitles = YES;
    [navs addObject:nav];
  }
  self.viewControllers = navs;
}

/* Over a running program the launcher is a sheet, which fills the screen in
 * landscape with no edge to swipe down: each tab gets a Close button there. */
- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  BOOL sheet = self.modalPresentationStyle == UIModalPresentationPageSheet;
  for (UINavigationController *nav in self.viewControllers)
    nav.viewControllers.firstObject.navigationItem.leftBarButtonItem = sheet
        ? [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(onClose)]
        : nil;
}

- (void)onClose {
  [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)refreshAll {
  for (UINavigationController *nav in self.viewControllers)
    for (UIViewController *vc in nav.viewControllers)
      if ([vc respondsToSelector:@selector(refresh)]) [vc performSelector:@selector(refresh)];
}

- (void)report:(NSString *)title message:(NSString *)msg {
  UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg
                                                      preferredStyle:UIAlertControllerStyleAlert];
  [a addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil) style:UIAlertActionStyleDefault handler:nil]];
  UIViewController *top = self;
  while (top.presentedViewController) top = top.presentedViewController;
  [top presentViewController:a animated:YES completion:nil];
}

@end

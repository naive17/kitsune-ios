#import "settings_vc.h"

#import "launcher_vc.h"
#import "progress_vc.h"
#include "app_library.h"
#include "bottles.h"
#include "diagnostics.h"
#include "launcher_settings.h"
#include "power.h"
#include "reset.h"
#include "runtime_tree.h"
#include "wine_boot.h"

typedef NS_ENUM(NSInteger, SettingsSection) {
  SecDisplay = 0, SecPerformance, SecControls, SecSteam, SecDiagnostics, SecStorage, SecAbout, SecCount
};

static const double kScales[] = { 0.0, 1.7, 2.0, 2.5, 3.0 };
static const double kLookSens[] = { 0.5, 1.0, 1.5, 2.0, 3.0 };
static const int kFrameCaps[] = { 0, 30, 40, 60 };

static NSInteger IndexOf(const double *values, NSInteger count, double v) {
  NSInteger best = 0;
  for (NSInteger i = 0; i < count; i++)
    if (fabs(values[i] - v) < fabs(values[best] - v)) best = i;
  return best;
}

static UITableViewCell *SwitchRow(NSString *title, NSString *detail, BOOL on, id target, SEL action) {
  UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
  cell.selectionStyle = UITableViewCellSelectionStyleNone;
  cell.textLabel.text = title;
  cell.textLabel.numberOfLines = 0;
  cell.detailTextLabel.text = detail;
  cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
  cell.detailTextLabel.numberOfLines = 0;
  UISwitch *sw = [UISwitch new];
  sw.on = on;
  [sw addTarget:target action:action forControlEvents:UIControlEventValueChanged];
  cell.accessoryView = sw;
  return cell;
}

/* The title above full-width choices, so neither gets cut short. */
static UITableViewCell *ChoiceRow(NSString *title, NSString *detail, NSArray<NSString *> *choices, NSInteger selected,
                                  id target, SEL action) {
  UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
  cell.selectionStyle = UITableViewCellSelectionStyleNone;
  UILabel *label = [UILabel new];
  label.text = title;
  label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
  label.adjustsFontForContentSizeCategory = YES;
  NSMutableArray<UIView *> *views = [NSMutableArray arrayWithObject:label];
  if (detail.length) {
    UILabel *d = [UILabel new];
    d.text = detail;
    d.numberOfLines = 0;
    d.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    d.adjustsFontForContentSizeCategory = YES;
    d.textColor = UIColor.secondaryLabelColor;
    [views addObject:d];
  }
  UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:choices];
  seg.selectedSegmentIndex = selected;
  [seg addTarget:target action:action forControlEvents:UIControlEventValueChanged];
  [views addObject:seg];
  UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:views];
  stack.axis = UILayoutConstraintAxisVertical;
  stack.spacing = 2;
  [stack setCustomSpacing:10 afterView:views[views.count - 2]];
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  [cell.contentView addSubview:stack];
  UILayoutGuide *m = cell.contentView.layoutMarginsGuide;
  [NSLayoutConstraint activateConstraints:@[
    [stack.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
    [stack.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
    [stack.topAnchor constraintEqualToAnchor:m.topAnchor],
    [stack.bottomAnchor constraintEqualToAnchor:m.bottomAnchor],
  ]];
  return cell;
}

static UITableViewCell *TextRow(NSString *title, NSString *detail, UIColor *color, BOOL selectable) {
  UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
  cell.selectionStyle = selectable ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
  cell.textLabel.text = title;
  cell.textLabel.textColor = color ?: UIColor.labelColor;
  cell.detailTextLabel.text = detail;
  cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
  cell.detailTextLabel.numberOfLines = 0;
  return cell;
}

@implementation WineSettingsVC {
  NSString *_cacheSize;
  NSString *_treeVersion;
}

- (instancetype)init {
  if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) self.title = NSLocalizedString(@"Settings", nil);
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  [self refresh];
}

- (void)refresh {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    unsigned long long cache = KitsuneDirectorySize(WineShaderCacheRoot());
    NSString *tree = KitsuneTreeVersion(WineTreeRoot());
    dispatch_async(dispatch_get_main_queue(), ^{
      self->_cacheSize = [NSString stringWithFormat:NSLocalizedString(@"%llu MB", nil), cache >> 20];
      self->_treeVersion = tree.length ? tree : NSLocalizedString(@"Not installed", nil);
      [self.tableView reloadData];
    });
  });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)t { return SecCount; }

- (NSInteger)tableView:(UITableView *__unused)t numberOfRowsInSection:(NSInteger)s {
  switch (s) {
  case SecDisplay: return 4;
  case SecPerformance: return 5;
  case SecControls: return 2;
  case SecSteam: return 1;
  case SecDiagnostics: return 2;
  case SecStorage: return 3;
  case SecAbout: return 4;
  default: return 0;
  }
}

- (NSString *)tableView:(UITableView *__unused)t titleForHeaderInSection:(NSInteger)s {
  switch (s) {
  case SecDisplay: return NSLocalizedString(@"Display", nil);
  case SecPerformance: return NSLocalizedString(@"Performance", nil);
  case SecControls: return NSLocalizedString(@"Controls", nil);
  case SecSteam: return NSLocalizedString(@"Steam", nil);
  case SecDiagnostics: return NSLocalizedString(@"Diagnostics", nil);
  case SecStorage: return NSLocalizedString(@"Storage", nil);
  case SecAbout: return NSLocalizedString(@"About", nil);
  default: return nil;
  }
}

- (NSString *)tableView:(UITableView *__unused)t titleForFooterInSection:(NSInteger)s {
  switch (s) {
  case SecDisplay:
    return NSLocalizedString(@"Applies the next time a program starts.", nil);
  case SecPerformance:
    return NSLocalizedString(@"Battery caps games at 30 fps and turns on by itself when the phone gets hot.", nil);
  case SecDiagnostics:
    return NSLocalizedString(@"Applies the next time Kitsune opens. Full logging slows programs down.", nil);
  case SecStorage:
    return NSLocalizedString(@"Keeps the Wine runtime and your settings.", nil);
  default: return nil;
  }
}

- (UITableViewCell *)tableView:(UITableView *__unused)t cellForRowAtIndexPath:(NSIndexPath *)ip {
  NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
  switch (ip.section) {
  case SecDisplay:
    switch (ip.row) {
    case 0: return SwitchRow(NSLocalizedString(@"Avoid the Notch", nil), NSLocalizedString(@"Keep windows clear of the notch", nil),
                             KitsuneSafeAreaStored(ud), self, @selector(onSafeArea:));
    case 1: return SwitchRow(NSLocalizedString(@"Fit Games to the Screen", nil), NSLocalizedString(@"Match supported games to the screen", nil),
                             KitsuneFillScreenStored(ud), self, @selector(onFillScreen:));
    case 2: return ChoiceRow(NSLocalizedString(@"Resolution", nil), NSLocalizedString(@"Higher is sharper and uses more memory", nil),
                             @[ NSLocalizedString(@"Auto", nil), NSLocalizedString(@"1.7×", nil), NSLocalizedString(@"2×", nil), NSLocalizedString(@"2.5×", nil), NSLocalizedString(@"3×", nil) ],
                             IndexOf(kScales, 5, KitsuneRenderScaleStored(ud)), self, @selector(onScale:));
    default: return ChoiceRow(NSLocalizedString(@"Other Programs", nil), NSLocalizedString(@"Orientation for programs that aren't games", nil),
                              @[ NSLocalizedString(@"Portrait", nil), NSLocalizedString(@"Landscape", nil) ], [ud boolForKey:KITSUNE_KEY_OTHER_LANDSCAPE] ? 1 : 0,
                              self, @selector(onOrientation:));
    }
  case SecPerformance:
    switch (ip.row) {
    case 0: return ChoiceRow(NSLocalizedString(@"Power Mode", nil), nil, @[ NSLocalizedString(@"Balanced", nil), NSLocalizedString(@"Performance", nil), NSLocalizedString(@"Battery", nil) ],
                             WinePower.shared.userMode, self, @selector(onPowerMode:));
    case 1: {
      int cap = KitsuneFrameCapStored(ud);
      return ChoiceRow(NSLocalizedString(@"Frame Rate Limit", nil), NSLocalizedString(@"Lower saves battery", nil),
                       @[ NSLocalizedString(@"None", nil), @"30", @"40", @"60" ], cap == 30 ? 1 : cap == 40 ? 2 : cap == 60 ? 3 : 0,
                       self, @selector(onFrameCap:));
    }
    case 2: return ChoiceRow(NSLocalizedString(@"Texture Size", nil), NSLocalizedString(@"Smaller uses less memory", nil),
                             @[ NSLocalizedString(@"Small", nil), NSLocalizedString(@"Medium", nil), NSLocalizedString(@"Full", nil) ], KitsuneTextureModeStored(ud), self, @selector(onTextures:));
    case 3: return SwitchRow(NSLocalizedString(@"Battery Mode in Low Power Mode", nil), nil, KitsuneLowPowerAutoStored(ud), self, @selector(onLowPower:));
    default: return SwitchRow(NSLocalizedString(@"Performance Overlay", nil), NSLocalizedString(@"Frame rate and memory while playing", nil),
                              KitsunePerfHUDStored(ud), self, @selector(onPerfHUD:));
    }
  case SecControls:
    if (ip.row == 0)
      return ChoiceRow(NSLocalizedString(@"Camera Sensitivity", nil), NSLocalizedString(@"Used in look mode", nil),
                       @[ NSLocalizedString(@"0.5×", nil), NSLocalizedString(@"1×", nil), NSLocalizedString(@"1.5×", nil), NSLocalizedString(@"2×", nil), NSLocalizedString(@"3×", nil) ], IndexOf(kLookSens, 5, KitsuneLookSensitivityStored(ud)),
                       self, @selector(onLookSens:));
    return SwitchRow(NSLocalizedString(@"On-Screen Controller", nil), NSLocalizedString(@"For Steam games without a controller", nil),
                     KitsuneTouchPadStored(ud), self, @selector(onTouchPad:));
  case SecSteam:
    return ChoiceRow(NSLocalizedString(@"Steam Window", nil), NSLocalizedString(@"When opening Steam; games always start it hidden", nil), @[ NSLocalizedString(@"Visible", nil), NSLocalizedString(@"Hidden", nil) ],
                     KitsuneSteamVisibleStored(ud) ? 0 : 1, self, @selector(onSteamWindow:));
  case SecDiagnostics:
    if (ip.row == 0)
      return ChoiceRow(NSLocalizedString(@"Logging", nil), nil, @[ NSLocalizedString(@"Off", nil), NSLocalizedString(@"Basic", nil), NSLocalizedString(@"Full", nil) ], KitsuneDiagLevelStored(ud), self, @selector(onDiagnostics:));
    return SwitchRow(NSLocalizedString(@"Metal Performance HUD", nil), NSLocalizedString(@"GPU timings overlay", nil), [ud boolForKey:KITSUNE_KEY_METAL_HUD],
                     self, @selector(onMetalHUD:));
  case SecStorage:
    if (ip.row == 0)
      return TextRow(NSLocalizedString(@"Clear Shader Cache", nil),
                     _cacheSize ?: NSLocalizedString(@"Calculating…", nil),
                     nil, YES);
    if (ip.row == 1) return TextRow(NSLocalizedString(@"Clear Logs", nil), nil, nil, YES);
    return TextRow(NSLocalizedString(@"Remove All Programs and Bottles…", nil), nil, UIColor.systemRedColor, YES);
  default: {
    NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"0.1";
    if (ip.row == 0) return TextRow(NSLocalizedString(@"Version", nil), [NSString stringWithFormat:NSLocalizedString(@"%@, built %s", nil), version, __DATE__], nil, NO);
    if (ip.row == 1) return TextRow(NSLocalizedString(@"Wine Runtime", nil), _treeVersion ?: NSLocalizedString(@"Checking…", nil), nil, NO);
    if (ip.row == 2)
      return TextRow(NSLocalizedString(@"Licenses", nil), NSLocalizedString(@"Kitsune (GPL), Wine (LGPL), DXMT, FEX and others; included in the app", nil), nil, NO);
    return TextRow(NSLocalizedString(@"Share Logs", nil), nil, UIColor.systemBlueColor, YES);
  }
  }
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
  [t deselectRowAtIndexPath:ip animated:YES];
  if (ip.section == SecAbout && ip.row == 3) { [self shareLogsFrom:[t cellForRowAtIndexPath:ip]]; return; }
  if (ip.section != SecStorage) return;
  if (ip.row == 0) { KitsuneClearShaderCache(WineShaderCacheRoot()); [self refresh]; return; }
  if (ip.row == 1) { KitsuneClearLogs(KitsunePersistentDocuments()); return; }
  UIAlertController *a = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Remove Everything?", nil)
      message:NSLocalizedString(@"This deletes Steam, your games, imported programs and all bottles. Type “erase” to confirm.", nil)
      preferredStyle:UIAlertControllerStyleAlert];
  [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
    f.placeholder = NSLocalizedString(@"erase", nil);
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
  }];
  [a addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
  [a addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Remove", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x __unused) {
    if (![a.textFields.firstObject.text isEqualToString:NSLocalizedString(@"erase", nil)]) return;
    WineProgressVC *progress = [WineProgressVC presentFrom:self title:NSLocalizedString(@"Removing Everything", nil)];
    [progress setStage:NSLocalizedString(@"Removing…", nil) detail:nil fraction:-1];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      KitsuneRemoveEverything(KitsunePersistentDocuments(), WineShaderCacheRoot());
      NSString *err = nil;
      BOOL prefix = KitsuneCreateDefaultPrefix(KitsunePersistentDocuments(), WineTreeRoot(), &err);
      [WineAppLibrary.shared load];
      dispatch_async(dispatch_get_main_queue(), ^{
        if (prefix) [progress finish];
        else [progress failWithMessage:[NSLocalizedString(@"Removed, but the default bottle couldn't be recreated: ", nil)
                                           stringByAppendingString:err ?: NSLocalizedString(@"unknown error", nil)]];
        [(WineLauncherVC *)self.tabBarController refreshAll];
      });
    });
  }]];
  [self presentViewController:a animated:YES completion:nil];
}

- (void)shareLogsFrom:(UIView *)source {
  NSString *docs = KitsunePersistentDocuments();
  NSMutableArray<NSURL *> *files = [NSMutableArray array];
  for (NSString *n in [NSFileManager.defaultManager contentsOfDirectoryAtPath:docs error:nil])
    if ([n hasPrefix:@"wine-stderr.log"] || [n isEqualToString:@"hb.log"])
      [files addObject:[NSURL fileURLWithPath:[docs stringByAppendingPathComponent:n]]];
  NSString *steamLog = [docs stringByAppendingPathComponent:@"Apps/Steam/logs/console_log.txt"];
  if ([NSFileManager.defaultManager fileExistsAtPath:steamLog]) [files addObject:[NSURL fileURLWithPath:steamLog]];
  if (!files.count) { [(WineLauncherVC *)self.tabBarController report:NSLocalizedString(@"No Logs Yet", nil) message:NSLocalizedString(@"Nothing has been logged.", nil)]; return; }
  UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:files applicationActivities:nil];
  share.popoverPresentationController.sourceView = source ?: self.view;
  [self presentViewController:share animated:YES completion:nil];
}

- (void)onPowerMode:(UISegmentedControl *)seg { WinePower.shared.userMode = (WinePowerMode)seg.selectedSegmentIndex; }
- (void)onMetalHUD:(UISwitch *)sw { [NSUserDefaults.standardUserDefaults setBool:sw.on forKey:KITSUNE_KEY_METAL_HUD]; }
- (void)onPerfHUD:(UISwitch *)sw { [NSUserDefaults.standardUserDefaults setBool:sw.on forKey:KITSUNE_KEY_PERF_HUD]; }
- (void)onTouchPad:(UISwitch *)sw { [NSUserDefaults.standardUserDefaults setBool:sw.on forKey:KITSUNE_KEY_TOUCH_PAD]; }
- (void)onLookSens:(UISegmentedControl *)seg { [NSUserDefaults.standardUserDefaults setDouble:kLookSens[seg.selectedSegmentIndex] forKey:KITSUNE_KEY_LOOK_SENS]; }
- (void)onSafeArea:(UISwitch *)sw { [NSUserDefaults.standardUserDefaults setBool:sw.on forKey:KITSUNE_KEY_SAFE_AREA]; }
- (void)onFillScreen:(UISwitch *)sw { [NSUserDefaults.standardUserDefaults setBool:sw.on forKey:KITSUNE_KEY_FILL_SCREEN]; }
- (void)onScale:(UISegmentedControl *)seg { [NSUserDefaults.standardUserDefaults setDouble:kScales[seg.selectedSegmentIndex] forKey:KITSUNE_KEY_RENDER_SCALE]; }
- (void)onOrientation:(UISegmentedControl *)seg { [NSUserDefaults.standardUserDefaults setBool:seg.selectedSegmentIndex == 1 forKey:KITSUNE_KEY_OTHER_LANDSCAPE]; }
- (void)onFrameCap:(UISegmentedControl *)seg { [NSUserDefaults.standardUserDefaults setInteger:kFrameCaps[seg.selectedSegmentIndex] forKey:KITSUNE_KEY_FRAME_CAP]; }
- (void)onTextures:(UISegmentedControl *)seg { [NSUserDefaults.standardUserDefaults setInteger:seg.selectedSegmentIndex forKey:KITSUNE_KEY_TEXTURES]; }
- (void)onLowPower:(UISwitch *)sw { [NSUserDefaults.standardUserDefaults setBool:sw.on forKey:KITSUNE_KEY_LOW_POWER_AUTO]; }
- (void)onSteamWindow:(UISegmentedControl *)seg { [NSUserDefaults.standardUserDefaults setBool:seg.selectedSegmentIndex == 0 forKey:KITSUNE_KEY_STEAM_VISIBLE]; }
- (void)onDiagnostics:(UISegmentedControl *)seg { KitsuneDiagStore(NSUserDefaults.standardUserDefaults, (KitsuneDiagLevel)seg.selectedSegmentIndex); }

@end

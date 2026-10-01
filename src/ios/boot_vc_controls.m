#import "boot_vc_private.h"

#import <GameController/GameController.h>

#include "diagnostics.h"
#include "launcher_settings.h"
#include "task_manager.h"
#include "touch_gamepad_layout.h"

static BOOL PhysicalControllerConnected(void) {
  for (GCController *c in GCController.controllers)
    if (c.extendedGamepad) return YES;
  return NO;
}

@implementation WineBootVC (Controls)

/* --- in-session controls ------------------------------------------------- */

- (void)showInputLayer {
  if (_input) return;
  /* A running program gets the screen: no boot status behind its windows. */
  self.view.backgroundColor = UIColor.blackColor;
  for (UIView *v in @[ _stage, _spinner, _bar, _details, _out, _libraryBtn ]) v.hidden = YES;
  _input = [[WineInputOverlay alloc] initWithFrame:self.view.bounds];
  _input.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  _input.layer.zPosition = 2000;   /* above the Wine layers at 1000 */
  [self.view addSubview:_input];

  UIButton *(^mk)(NSString *, NSString *, SEL) = ^UIButton *(NSString *symbol, NSString *fallback, SEL action) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    if (@available(iOS 26.0, *)) b.configuration = [UIButtonConfiguration glassButtonConfiguration];
    UIImage *img = [UIImage systemImageNamed:symbol];
    if (img) {
      [b setImage:img forState:UIControlStateNormal];
      b.tintColor = UIColor.whiteColor;
    } else {
      [b setTitle:fallback forState:UIControlStateNormal];
      [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
      b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    }
    b.accessibilityLabel = fallback;
    b.layer.cornerRadius = 15;
    b.clipsToBounds = YES;
    [b.widthAnchor constraintEqualToConstant:KITSUNE_BAR_BUTTON_WIDTH].active = YES;
    [b.heightAnchor constraintEqualToConstant:30].active = YES;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
  };
  _modeButton = mk(@"hand.tap", NSLocalizedString(@"mode", nil), @selector(onToggleMode));
  _padButton = mk(@"gamecontroller", NSLocalizedString(@"controller", nil), @selector(onTogglePad));
  _ctrlButton = mk(@"control", NSLocalizedString(@"ctrl", nil), @selector(onCtrl));
  _altButton = mk(@"option", NSLocalizedString(@"alt", nil), @selector(onAlt));
  _powerButton = mk(@"leaf", NSLocalizedString(@"eco", nil), @selector(onTogglePower));
  _barButtons = @[
      mk(@"square.grid.2x2",         NSLocalizedString(@"library", nil), @selector(onShowLibraryOverProgram)),
      _modeButton,
      _padButton,
      mk(@"keyboard",                NSLocalizedString(@"kbd", nil),  @selector(onToggleKeyboard)),
      mk(@"escape",                  NSLocalizedString(@"esc", nil),  @selector(onEsc)),
      mk(@"arrow.right.to.line",     NSLocalizedString(@"tab", nil),  @selector(onTab)),
      _ctrlButton,
      _altButton,
      mk(@"1.magnifyingglass",       NSLocalizedString(@"1:1", nil),  @selector(onResetZoom)),
      mk(@"list.bullet.rectangle",   NSLocalizedString(@"apps", nil), @selector(onShowTasks)),
      _powerButton,
      mk(@"xmark",                   NSLocalizedString(@"hide", nil), @selector(onHideInput)),
  ];
  NSAssert(_barButtons.count == KITSUNE_BAR_BUTTONS, @"the pad layout reserves room for %d bar buttons", KITSUNE_BAR_BUTTONS);
  UIStackView *(^row)(void) = ^UIStackView *(void) {
    UIStackView *r = [UIStackView new];
    r.axis = UILayoutConstraintAxisHorizontal;
    r.alignment = UIStackViewAlignmentCenter;
    r.spacing = 2;
    return r;
  };
  _barRows = @[ row(), row() ];
  UIStackView *bar = [[UIStackView alloc] initWithArrangedSubviews:_barRows];
  bar.axis = UILayoutConstraintAxisVertical;
  bar.alignment = UIStackViewAlignmentCenter;
  bar.spacing = 2;
  bar.layoutMarginsRelativeArrangement = YES;
  bar.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(4, 8, 4, 8);
  bar.translatesAutoresizingMaskIntoConstraints = NO;
  [self arrangeBar];

  UIVisualEffect *material;
  if (@available(iOS 26.0, *)) {
    UIGlassEffect *glass = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
    glass.interactive = YES;
    material = glass;
  } else {
    material = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark];
  }
  UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:material];
  blur.translatesAutoresizingMaskIntoConstraints = NO;
  blur.layer.cornerRadius = 19;
  blur.clipsToBounds = YES;
  blur.layer.zPosition = 2001;
  [self.view addSubview:blur];
  [blur.contentView addSubview:bar];
  _inputBarChrome = blur;

  _showBar = [UIButton buttonWithType:UIButtonTypeSystem];
  [_showBar setImage:[UIImage systemImageNamed:@"keyboard.chevron.compact.down"] forState:UIControlStateNormal];
  _showBar.tintColor = UIColor.whiteColor;
  _showBar.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.4];
  _showBar.layer.cornerRadius = 14;
  _showBar.layer.zPosition = 2001;
  _showBar.translatesAutoresizingMaskIntoConstraints = NO;
  _showBar.hidden = YES;
  [_showBar addTarget:self action:@selector(onShowInput) forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:_showBar];

  _hud = [WinePerfHUD new];
  _hud.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:_hud];

  UILayoutGuide *g = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [bar.topAnchor constraintEqualToAnchor:blur.contentView.topAnchor],
    [bar.bottomAnchor constraintEqualToAnchor:blur.contentView.bottomAnchor],
    [bar.leadingAnchor constraintEqualToAnchor:blur.contentView.leadingAnchor],
    [bar.trailingAnchor constraintEqualToAnchor:blur.contentView.trailingAnchor],
    [blur.centerXAnchor constraintEqualToAnchor:g.centerXAnchor],
    [_showBar.widthAnchor constraintEqualToConstant:36],
    [_showBar.heightAnchor constraintEqualToConstant:28],
  ]];
  /* The pad owns the bottom corners and the screen edges, so while it is shown
   * the bar, its show button and the overlay sit at the top centre, the band
   * KitsunePadReservedTop keeps clear. */
  _chromeBottom = @[
    [blur.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-8],
    [_showBar.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-8],
    [_showBar.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-8],
    [_hud.topAnchor constraintEqualToAnchor:g.topAnchor constant:6],
    [_hud.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:8],
  ];
  _chromeTop = @[
    [blur.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
    [_showBar.centerXAnchor constraintEqualToAnchor:g.centerXAnchor],
    [_showBar.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
    [_hud.topAnchor constraintEqualToAnchor:blur.bottomAnchor constant:6],
    [_hud.centerXAnchor constraintEqualToAnchor:g.centerXAnchor],
  ];
  [NSLayoutConstraint activateConstraints:_chromeBottom];

  NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
  _input.lookSensitivity = KitsuneLookSensitivityStored(ud);
  _Static_assert(WinePointerTouch == 0 && WinePointerTrackpad == 1 && WinePointerLook == 2,
                 "KitsunePointerModeStored returns these values");
  _input.pointerMode = (WinePointerMode)KitsunePointerModeStored(ud);
  [self updateModeButton];
  [self updateHUD];
  [self updatePowerButton];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updatePowerButton)
                                             name:WinePowerDidChangeNotification object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateHUD)
                                             name:NSUserDefaultsDidChangeNotification object:nil];

  _padWanted = KitsuneTouchPadStored(ud) && [_request[@"args"] containsObject:@"-applaunch"];
  __weak WineBootVC *weakSelf = self;
  for (NSNotificationName name in @[ GCControllerDidConnectNotification, GCControllerDidDisconnectNotification ])
    [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n __unused) { [weakSelf applyPad]; }];
  [self applyPad];
}

/* One row when the safe width holds every button, else two. */
- (void)arrangeBar {
  if (!_barButtons) return;
  UIEdgeInsets inset = self.view.safeAreaInsets;
  BOOL oneRow = KitsuneBarRows(self.view.bounds.size.width - inset.left - inset.right) == 1;
  NSUInteger split = oneRow ? _barButtons.count : (_barButtons.count + 1) / 2;
  for (NSUInteger i = 0; i < _barButtons.count; i++) {
    UIStackView *target = _barRows[i < split ? 0 : 1];
    if (_barButtons[i].superview != target) [target addArrangedSubview:_barButtons[i]];
  }
  _barRows[1].hidden = oneRow;
}

- (void)onTogglePad {
  _padWanted = !_padWanted;
  [self applyPad];
}

/* A physical controller takes over from the pad; the pad returns when the
 * last one disconnects. */
- (void)applyPad {
  BOOL show = _padWanted && !PhysicalControllerConnected();
  if (show && !_pad) {
    _pad = [[WineTouchGamepad alloc] initWithFrame:self.view.bounds];
    _pad.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _pad.layer.zPosition = 2000;
    [self.view addSubview:_pad];
  }
  _pad.hidden = !show;
  _padButton.tintColor = _padWanted ? UIColor.systemYellowColor : UIColor.whiteColor;
  NSArray<NSLayoutConstraint *> *off = show ? _chromeBottom : _chromeTop;
  NSArray<NSLayoutConstraint *> *on = show ? _chromeTop : _chromeBottom;
  [NSLayoutConstraint deactivateConstraints:off];
  [NSLayoutConstraint activateConstraints:on];
}

/* Switches to Battery, live; a second tap restores the mode chosen before. */
- (void)onTogglePower {
  WinePower *power = WinePower.shared;
  if (power.userMode == WinePowerBattery) {
    power.userMode = _modeBeforeBattery;
  } else {
    _modeBeforeBattery = power.userMode;
    power.userMode = WinePowerBattery;
  }
  [self updatePowerButton];
}

- (void)updatePowerButton {
  _powerButton.tintColor = WinePower.shared.effectiveMode == WinePowerBattery ? UIColor.systemGreenColor : UIColor.whiteColor;
  [self updateHUD];
}

/* The overlay's switch is in Settings, which the Library shows over a program.
 * It is shown whenever logging or Battery is on or iOS is throttling a hot
 * phone, which it announces, even with the switch off. setVisible restarts the
 * frame count, so only on a change. Thermal changes arrive through
 * WinePowerDidChangeNotification. */
- (void)updateHUD {
  BOOL want = KitsunePerfHUDStored(NSUserDefaults.standardUserDefaults) || KitsuneDiagLevelFromEnv() != KitsuneDiagOff ||
              WinePower.shared.effectiveMode == WinePowerBattery ||
              NSProcessInfo.processInfo.thermalState >= NSProcessInfoThermalStateSerious;
  if (_hud.hidden == want) [_hud setVisible:want];
}

- (void)updateModeButton {
  static NSString *const symbols[] = { @"hand.tap", @"cursorarrow.motionlines", @"scope" };
  static NSString *const titles[] = { @"tap", @"pad", @"look" };
  NSInteger m = _input.pointerMode;
  UIImage *img = [UIImage systemImageNamed:symbols[m]];
  if (img) [_modeButton setImage:img forState:UIControlStateNormal];
  else [_modeButton setTitle:NSLocalizedString(titles[m], nil) forState:UIControlStateNormal];
  _modeButton.accessibilityLabel = NSLocalizedString(titles[m], nil);
}

- (void)onToggleMode {
  _input.pointerMode = (WinePointerMode)((_input.pointerMode + 1) % 3);
  [NSUserDefaults.standardUserDefaults setInteger:_input.pointerMode forKey:KITSUNE_KEY_POINTER_MODE];
  [self updateModeButton];
}
- (void)onToggleKeyboard { [_input toggleKeyboard]; }
- (void)onEsc  { [_input pressSpecial:WineKeyEsc]; }
- (void)onTab  { [_input pressSpecial:WineKeyTab]; }
- (void)onCtrl { [_input pressSpecial:WineKeyCtrl]; [self mark:_ctrlButton on:[_input ctrlHeld]]; }
- (void)onAlt  { [_input pressSpecial:WineKeyAlt];  [self mark:_altButton on:[_input altHeld]]; }
- (void)onResetZoom { [_input resetZoom]; }

- (void)mark:(UIButton *)b on:(BOOL)on {
  b.tintColor = on ? UIColor.systemYellowColor : UIColor.whiteColor;
}

- (void)onShowTasks {
  UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[WineTaskListVC new]];
  nav.modalPresentationStyle = UIModalPresentationPageSheet;
  [self presentViewController:nav animated:YES completion:nil];
}

- (void)onHideInput {
  _inputBarChrome.hidden = YES;
  _showBar.hidden = NO;
}

- (void)onShowInput {
  _showBar.hidden = YES;
  _inputBarChrome.hidden = NO;
}

@end

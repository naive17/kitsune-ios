#import "progress_vc.h"

@implementation WineProgressVC {
  UILabel *_title;
  UILabel *_stage;
  UILabel *_detail;
  UIProgressView *_bar;
  UIActivityIndicatorView *_spinner;
  UIButton *_done;
}

+ (instancetype)presentFrom:(UIViewController *)host title:(NSString *)title {
  WineProgressVC *vc = [WineProgressVC new];
  vc.title = title;
  vc.modalPresentationStyle = UIModalPresentationPageSheet;
  vc.modalInPresentation = YES;
  if (@available(iOS 15.0, *)) {
    vc.sheetPresentationController.detents = @[ UISheetPresentationControllerDetent.mediumDetent ];
    vc.sheetPresentationController.prefersGrabberVisible = NO;
  }
  [host presentViewController:vc animated:YES completion:nil];
  return vc;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  _title = [UILabel new];
  _title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
  _title.text = self.title;
  _stage = [UILabel new];
  _stage.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
  _stage.numberOfLines = 2;
  _detail = [UILabel new];
  _detail.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
  _detail.textColor = UIColor.secondaryLabelColor;
  _detail.numberOfLines = 2;
  _bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
  _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
  _spinner.hidesWhenStopped = YES;
  [_spinner startAnimating];
  _done = [UIButton buttonWithType:UIButtonTypeSystem];
  [_done setTitle:NSLocalizedString(@"Done", nil) forState:UIControlStateNormal];
  _done.titleLabel.font = [UIFont boldSystemFontOfSize:17];
  [_done addTarget:self action:@selector(onDone) forControlEvents:UIControlEventTouchUpInside];
  _done.hidden = YES;

  UIStackView *barRow = [[UIStackView alloc] initWithArrangedSubviews:@[ _bar, _spinner ]];
  barRow.axis = UILayoutConstraintAxisHorizontal;
  barRow.spacing = 12;
  barRow.alignment = UIStackViewAlignmentCenter;
  UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:@[ _title, _stage, barRow, _detail, _done ]];
  column.axis = UILayoutConstraintAxisVertical;
  column.spacing = 14;
  column.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:column];
  UILayoutGuide *g = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [column.topAnchor constraintEqualToAnchor:g.topAnchor constant:28],
    [column.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:24],
    [column.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-24],
  ]];
}

- (void)setStage:(NSString *)stage detail:(NSString *)detail fraction:(double)fraction {
  _stage.text = stage;
  _detail.text = detail;
  if (fraction < 0) {
    _bar.hidden = YES;
    [_spinner startAnimating];
  } else {
    _bar.hidden = NO;
    [_spinner stopAnimating];
    [_bar setProgress:(float)MIN(1.0, fraction) animated:YES];
  }
}

- (void)finish {
  /* Work that ends before the sheet is up closes it once it is. */
  id<UIViewControllerTransitionCoordinator> tc = self.transitionCoordinator;
  if (tc) [tc animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> c __unused) {
    [self dismissViewControllerAnimated:YES completion:nil];
  }];
  else [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)failWithMessage:(NSString *)message {
  _stage.text = message;
  _stage.textColor = UIColor.systemRedColor;
  _detail.text = nil;
  _bar.hidden = YES;
  [_spinner stopAnimating];
  _done.hidden = NO;
  self.modalInPresentation = NO;
}

- (void)onDone {
  [self dismissViewControllerAnimated:YES completion:nil];
}

@end

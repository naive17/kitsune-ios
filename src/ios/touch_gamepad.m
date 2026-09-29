#import "touch_gamepad.h"

#import "game_controller.h"
#include "gamepad_state.h"
#include "touch_gamepad_layout.h"

/* A tap on a stick followed by a touch within this window clicks the stick
 * (L3/R3) for as long as the second touch lasts. */
static const NSTimeInterval kClickWindow = 0.3;
static const NSTimeInterval kTapDuration = 0.25;

static const uint16_t kThumbButton[2] = { 0x0040, 0x0080 };

static inline CGRect RectOf(IOSWinePadRect r) { return CGRectMake(r.x, r.y, r.w, r.h); }
static inline BOOL IsFace(int c) { return c >= TP_A && c <= TP_Y; }
static inline BOOL IsDpad(int c) { return c >= TP_UP && c <= TP_RIGHT; }
static inline int StickOf(int c) { return c == TP_LSTICK ? 0 : c == TP_RSTICK ? 1 : -1; }

@implementation WineTouchGamepad {
  IOSWinePadRect _rects[TP_COUNT];
  CGFloat _unit;
  CAShapeLayer *_shapes[TP_COUNT];
  CATextLayer *_labels[TP_COUNT];
  CAShapeLayer *_knobs[2];
  NSMapTable<UITouch *, NSNumber *> *_owners;
  UITouch *_stickTouch[2];
  CGPoint _stickOrigin[2];
  NSTimeInterval _stickDownAt[2];
  NSTimeInterval _stickTapAt[2];
  CGFloat _stickTravel[2];
  BOOL _stickClick[2];
  struct ios_touch_pad _state;
  UIImpactFeedbackGenerator *_haptic;
}

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.multipleTouchEnabled = YES;
    self.backgroundColor = UIColor.clearColor;
    _owners = [NSMapTable strongToStrongObjectsMapTable];
    _haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    _stickTapAt[0] = _stickTapAt[1] = -1;
    for (int i = 0; i < TP_COUNT; i++) {
      CAShapeLayer *s = [CAShapeLayer layer];
      s.strokeColor = [UIColor colorWithWhite:1 alpha:0.45].CGColor;
      s.lineWidth = 1.5;
      [self.layer addSublayer:s];
      _shapes[i] = s;
      CATextLayer *l = [CATextLayer layer];
      l.string = NSLocalizedString(@(kIOSWinePadLabel[i]), nil);
      l.alignmentMode = kCAAlignmentCenter;
      l.foregroundColor = [UIColor colorWithWhite:1 alpha:0.85].CGColor;
      l.font = (__bridge CFTypeRef)[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
      [s addSublayer:l];
      _labels[i] = l;
    }
    for (int k = 0; k < 2; k++) {
      _knobs[k] = [CAShapeLayer layer];
      _knobs[k].fillColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
      [self.layer addSublayer:_knobs[k]];
    }
  }
  return self;
}

- (void)safeAreaInsetsDidChange {
  [super safeAreaInsetsDidChange];
  [self setNeedsLayout];
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CGSize size = self.bounds.size;
  UIEdgeInsets inset = self.safeAreaInsets;
  IOSWinePadScreen screen = { size.width, size.height, inset.left, inset.top, inset.right, inset.bottom };
  _unit = IOSWinePadLayout(screen, _rects);
  CGFloat scale = self.traitCollection.displayScale;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  for (int i = 0; i < TP_COUNT; i++) {
    CGRect r = RectOf(_rects[i]);
    CGRect local = CGRectMake(0, 0, r.size.width, r.size.height);
    BOOL round = StickOf(i) >= 0 || IsFace(i);
    _shapes[i].frame = r;
    _shapes[i].path = (round ? [UIBezierPath bezierPathWithOvalInRect:local]
                             : [UIBezierPath bezierPathWithRoundedRect:local cornerRadius:MIN(r.size.height / 2, 10)]).CGPath;
    CGFloat fontSize = IsFace(i) ? 0.36 * _unit : IsDpad(i) ? 0.3 * _unit : 0.24 * _unit;
    _labels[i].fontSize = fontSize;
    _labels[i].contentsScale = scale;
    _labels[i].frame = CGRectMake(0, (r.size.height - fontSize * 1.25) / 2, r.size.width, fontSize * 1.25);
  }
  for (int k = 0; k < 2; k++) {
    CGFloat d = _rects[k ? TP_RSTICK : TP_LSTICK].w * 0.42;
    _knobs[k].bounds = CGRectMake(0, 0, d, d);
    _knobs[k].path = [UIBezierPath bezierPathWithOvalInRect:_knobs[k].bounds].CGPath;
  }
  [CATransaction commit];
  [self update];
}

- (CGRect)dpadRect {
  return CGRectUnion(CGRectUnion(RectOf(_rects[TP_UP]), RectOf(_rects[TP_DOWN])),
                     CGRectUnion(RectOf(_rects[TP_LEFT]), RectOf(_rects[TP_RIGHT])));
}

/* The nearest control whose slightly enlarged area holds p. The d-pad is one
 * control, answered as TP_UP. */
- (int)controlAt:(CGPoint)p {
  int best = -1;
  CGFloat bestDistance = CGFLOAT_MAX;
  for (int i = 0; i < TP_COUNT; i++) {
    if (IsDpad(i) && i != TP_UP) continue;
    CGRect r = IsDpad(i) ? [self dpadRect] : RectOf(_rects[i]);
    CGFloat grow = (StickOf(i) >= 0 ? 0.3 : 0.12) * _unit;
    r = CGRectInset(r, -grow, -grow);
    if (!CGRectContainsPoint(r, p)) continue;
    CGFloat d = hypot(p.x - CGRectGetMidX(r), p.y - CGRectGetMidY(r));
    if (d < bestDistance) { bestDistance = d; best = i; }
  }
  return best;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
  (void)event;
  return [self controlAt:point] >= 0;
}

/* Eight-way: within 30 degrees of an axis presses one direction, the rest of
 * each quadrant presses the two neighbours. */
- (uint16_t)dpadBitsAt:(CGPoint)p {
  static const uint16_t axis[4] = { 0x0008, 0x0001, 0x0004, 0x0002 };   /* right, up, left, down */
  CGRect r = [self dpadRect];
  CGFloat dx = p.x - CGRectGetMidX(r), dy = CGRectGetMidY(r) - p.y;
  if (hypot(dx, dy) < r.size.width * 0.1) return 0;
  double quarter = atan2(dy, dx) / M_PI_2;
  long nearest = lround(quarter);
  uint16_t bits = axis[nearest & 3];
  if (fabs(quarter - nearest) > 1.0 / 3) bits |= axis[(quarter > nearest ? nearest + 1 : nearest - 1) & 3];
  return bits;
}

- (CGFloat)stickRadius:(int)k {
  return _rects[k ? TP_RSTICK : TP_LSTICK].w * 0.4;
}

/* Stick offset from where the touch went down, in unit-circle coordinates
 * with y up. */
- (CGPoint)stickVector:(int)k at:(CGPoint)p {
  CGFloat radius = [self stickRadius:k];
  CGFloat x = (p.x - _stickOrigin[k].x) / radius, y = (_stickOrigin[k].y - p.y) / radius;
  CGFloat len = hypot(x, y);
  if (len > 1) { x /= len; y /= len; }
  return CGPointMake(x, y);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  (void)event;
  for (UITouch *t in touches) {
    CGPoint p = [t locationInView:self];
    int c = [self controlAt:p];
    if (c < 0) continue;
    int k = StickOf(c);
    if (k >= 0) {
      if (_stickTouch[k]) continue;
      _stickTouch[k] = t;
      _stickOrigin[k] = p;
      _stickDownAt[k] = t.timestamp;
      _stickTravel[k] = 0;
      _stickClick[k] = _stickTapAt[k] >= 0 && t.timestamp - _stickTapAt[k] < kClickWindow;
    }
    [_owners setObject:@(c) forKey:t];
  }
  [self update];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  (void)event;
  for (UITouch *t in touches) {
    NSNumber *owner = [_owners objectForKey:t];
    if (!owner) continue;
    int c = owner.intValue, k = StickOf(c);
    CGPoint p = [t locationInView:self];
    if (k >= 0) {
      _stickTravel[k] = MAX(_stickTravel[k], hypot(p.x - _stickOrigin[k].x, p.y - _stickOrigin[k].y));
    } else if (IsFace(c)) {
      int under = [self controlAt:p];
      if (IsFace(under) && under != c) [_owners setObject:@(under) forKey:t];
    }
  }
  [self update];
}

- (void)endTouches:(NSSet<UITouch *> *)touches {
  for (UITouch *t in touches) {
    NSNumber *owner = [_owners objectForKey:t];
    if (!owner) continue;
    int k = StickOf(owner.intValue);
    if (k >= 0 && _stickTouch[k] == t) {
      BOOL tap = t.timestamp - _stickDownAt[k] < kTapDuration && _stickTravel[k] < 0.2 * [self stickRadius:k];
      _stickTapAt[k] = tap && !_stickClick[k] ? t.timestamp : -1;
      _stickTouch[k] = nil;
      _stickClick[k] = NO;
    }
    [_owners removeObjectForKey:t];
  }
  [self update];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  (void)event;
  [self endTouches:touches];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  (void)event;
  [self endTouches:touches];
}

- (void)releaseAll {
  [_owners removeAllObjects];
  for (int k = 0; k < 2; k++) {
    _stickTouch[k] = nil;
    _stickClick[k] = NO;
    _stickTapAt[k] = -1;
  }
  [self update];
}

- (void)setHidden:(BOOL)hidden {
  [super setHidden:hidden];
  if (hidden) [self releaseAll];
  else [self update];
}

/* Rebuilds the pad state from the live touches, redraws, and publishes when
 * the state changed. */
- (void)update {
  struct ios_touch_pad s = { .active = !self.hidden };
  BOOL lit[TP_COUNT] = { NO };
  CGPoint stick[2] = { CGPointZero, CGPointZero };
  for (UITouch *t in _owners) {
    int c = [_owners objectForKey:t].intValue;
    CGPoint p = [t locationInView:self];
    int k = StickOf(c);
    if (k >= 0) {
      stick[k] = [self stickVector:k at:p];
      lit[c] = YES;
      if (_stickClick[k]) s.buttons |= kThumbButton[k];
    } else if (IsDpad(c)) {
      uint16_t bits = [self dpadBitsAt:p];
      s.buttons |= bits;
      for (int d = TP_UP; d <= TP_RIGHT; d++) if (bits & kIOSWinePadButton[d]) lit[d] = YES;
    } else if (c == TP_LT) {
      s.left_trigger = 255;
      lit[c] = YES;
    } else if (c == TP_RT) {
      s.right_trigger = 255;
      lit[c] = YES;
    } else {
      s.buttons |= kIOSWinePadButton[c];
      lit[c] = YES;
    }
  }
  s.lx = IOSWineGamepadAxis(stick[0].x);
  s.ly = IOSWineGamepadAxis(stick[0].y);
  s.rx = IOSWineGamepadAxis(stick[1].x);
  s.ry = IOSWineGamepadAxis(stick[1].y);

  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  for (int i = 0; i < TP_COUNT; i++)
    _shapes[i].fillColor = [UIColor colorWithWhite:1 alpha:lit[i] ? 0.4 : 0.1].CGColor;
  for (int k = 0; k < 2; k++) {
    CGRect base = RectOf(_rects[k ? TP_RSTICK : TP_LSTICK]);
    CGFloat radius = [self stickRadius:k];
    _knobs[k].position = CGPointMake(CGRectGetMidX(base) + stick[k].x * radius, CGRectGetMidY(base) - stick[k].y * radius);
  }
  [CATransaction commit];

  if (!memcmp(&s, &_state, sizeof s)) return;
  BOOL pressed = (s.buttons & ~_state.buttons) || (s.left_trigger && !_state.left_trigger) ||
                 (s.right_trigger && !_state.right_trigger);
  _state = s;
  GameController_SetTouchPad(&s);
  if (pressed) [_haptic impactOccurred];
}

@end

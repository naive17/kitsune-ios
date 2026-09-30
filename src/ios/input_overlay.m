
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#include "wine_surface.h"
#include "input_overlay.h"
#include "key_pulse.h"

/* Driver entry points (dlls/wineios.drv/input.c). */
static void (*drv_move)( int x, int y );
static void (*drv_move_rel)( int dx, int dy );
static void (*drv_button)( int button, int down );
static void (*drv_wheel)( int delta, int horizontal );
static void (*drv_key)( int vkey, int scan, int down );
static void (*drv_unicode)( int codepoint, int down );

int wine_input_overlay_alive;      /* the overlay exists at all */
int wine_input_gestures;           /* gestures recognised */
int wine_input_sent;               /* calls that reached the driver */
int wine_input_unmapped;           /* points that mapped to no window */
int wine_input_resolved;           /* bitmask of the six driver pointers */
int wine_input_last_x, wine_input_last_y;   /* last mapped screen coords */

const char *wine_input_status = "driver has not registered";

__attribute__((visibility("default")))
void wine_surface_host_register_input_status( const char *buf )
{
    if (buf) wine_input_status = buf;
}

/* The driver hands over its entry points; dlsym cannot see into its unix
 * library on iOS. */
__attribute__((visibility("default")))
void wine_surface_host_register_input( void *move, void *move_rel, void *button,
                                       void *wheel, void *key, void *unicode )
{
    drv_move     = move;
    drv_move_rel = move_rel;
    drv_button   = button;
    drv_wheel    = wheel;
    drv_key      = key;
    drv_unicode  = unicode;

    wine_input_resolved = (drv_move     ? 1  : 0) | (drv_move_rel ? 2  : 0) |
                          (drv_button   ? 4  : 0) | (drv_wheel    ? 8  : 0) |
                          (drv_key      ? 16 : 0) | (drv_unicode  ? 32 : 0);
}

/* Windows virtual-key codes, spelled out rather than including windef.h. */
enum { VK_BACK = 0x08, VK_TAB = 0x09, VK_RETURN = 0x0d, VK_SHIFT = 0x10,
       VK_CONTROL = 0x11, VK_MENU = 0x12, VK_ESCAPE = 0x1b, VK_PRIOR = 0x21,
       VK_NEXT = 0x22, VK_END = 0x23, VK_HOME = 0x24, VK_LEFT = 0x25,
       VK_UP = 0x26, VK_RIGHT = 0x27, VK_DOWN = 0x28, VK_DELETE = 0x2e,
       VK_F1 = 0x70 };

#define WHEEL_DELTA 120

@interface WineInputOverlay () <UITextFieldDelegate, UIGestureRecognizerDelegate>
@end

@implementation WineInputOverlay
{
    UIImageView *_cursor;      /* drawn by us: Wine's cursor is inside the layer */
    UITextField *_keys;        /* invisible; the system keyboard talks to this */
    UIToolbar   *_keyBar;      /* rides above the keyboard; carries Hide */
    CGPoint      _cursorPos;   /* in this view's coordinates */
    BOOL         _trackpad;
    BOOL         _ctrl, _alt;
    CGPoint      _panStart;
    struct ios_key_pulses _keyPulses;
    dispatch_source_t _keyPulseTimer;
    id _keyInactiveObserver;
    CGPoint _lookCarry;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if (!(self = [super initWithFrame:frame])) return nil;

    wine_input_overlay_alive = 1;
    _trackpad = YES;      /* the mode that can reach every pixel */
    self.backgroundColor = UIColor.clearColor;
    self.multipleTouchEnabled = YES;

    _cursorPos = CGPointMake( CGRectGetMidX( self.bounds ), CGRectGetMidY( self.bounds ) );
    _cursor = [[UIImageView alloc] initWithFrame:CGRectMake( 0, 0, 18, 24 )];
    _cursor.image = [self cursorImage];
    _cursor.userInteractionEnabled = NO;
    [self addSubview:_cursor];
    [self positionCursor];

    _keys = [[UITextField alloc] initWithFrame:CGRectMake( -100, -100, 10, 10 )];
    _keys.delegate = self;
    _keys.autocorrectionType = UITextAutocorrectionTypeNo;
    _keys.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _keys.spellCheckingType = UITextSpellCheckingTypeNo;
    _keys.smartQuotesType = UITextSmartQuotesTypeNo;
    _keys.smartDashesType = UITextSmartDashesTypeNo;
    _keys.keyboardType = UIKeyboardTypeASCIICapable;
    _keys.returnKeyType = UIReturnKeyDefault;
    /* A space keeps deleteBackward reachable: an empty field sends no
     * backspace, so there would be no way to correct anything. */
    _keys.text = @" ";
    _keys.inputAccessoryView = [self buildKeyboardBar];
    [self addSubview:_keys];

    __weak typeof(self) weakSelf = self;
    _keyInactiveObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:UIApplicationWillResignActiveNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            typeof(self) me = weakSelf;
            if (me) {
                KitsunePulseCancel(&me->_keyPulses, drv_key, drv_unicode);
                dispatch_source_set_timer(me->_keyPulseTimer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
            }
        }];
    _keyPulseTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_keyPulseTimer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(_keyPulseTimer, ^{
        typeof(self) me = weakSelf;
        if (me) {
            KitsunePulseTick(&me->_keyPulses, (uint64_t)(CACurrentMediaTime() * 1000), drv_key, drv_unicode);
            if (!me->_keyPulses.phase && me->_keyPulses.head == me->_keyPulses.tail)
                dispatch_source_set_timer(me->_keyPulseTimer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
        }
    });
    dispatch_resume(_keyPulseTimer);

    /* One finger: move, and tap to click. */
    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    pan.maximumNumberOfTouches = 1;
    pan.delegate = self;
    [self addGestureRecognizer:pan];

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)];
    tap.delegate = self;
    [self addGestureRecognizer:tap];

    /* Two fingers: right-click on tap, wheel on drag. */
    UITapGestureRecognizer *tap2 =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTwoTap:)];
    tap2.numberOfTouchesRequired = 2;
    tap2.delegate = self;
    [self addGestureRecognizer:tap2];

    UIPanGestureRecognizer *scroll =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onScroll:)];
    scroll.minimumNumberOfTouches = 2;
    scroll.maximumNumberOfTouches = 2;
    scroll.delegate = self;
    [self addGestureRecognizer:scroll];

    /* Press and hold: drag with the button down, for menus and selections. */
    UILongPressGestureRecognizer *hold =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onHold:)];
    hold.minimumPressDuration = 0.35;
    hold.delegate = self;
    [self addGestureRecognizer:hold];

    UIPinchGestureRecognizer *pinch =
        [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(onPinch:)];
    pinch.delegate = self;
    [self addGestureRecognizer:pinch];

    return self;
}

- (void)dealloc
{
    if (_keyPulseTimer) dispatch_source_cancel(_keyPulseTimer);
    if (_keyInactiveObserver) [NSNotificationCenter.defaultCenter removeObserver:_keyInactiveObserver];
    KitsunePulseCancel(&_keyPulses, drv_key, drv_unicode);
}

/* tag is key + 1 because WineKeyEsc is 0 and so is the tag of every item that
 * carries no key -- the flexible spaces, and Hide. Without the offset a space
 * would read as an Esc. */
- (UIBarButtonItem *)barItem:(NSString *)title key:(WineSpecialKey)key
{
    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithTitle:title
                                                            style:UIBarButtonItemStylePlain
                                                           target:self
                                                           action:@selector(onBarKey:)];
    item.tag = key + 1;
    return item;
}

- (UIView *)buildKeyboardBar
{
    UIToolbar *bar = [[UIToolbar alloc] initWithFrame:CGRectMake( 0, 0, 320, 44 )];
    UIBarButtonItem *gap = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];

    bar.barStyle = UIBarStyleBlack;
    bar.translucent = YES;
    bar.tintColor = UIColor.whiteColor;
    if (@available(iOS 15.0, *))
    {
        UIToolbarAppearance *a = [UIToolbarAppearance new];
        [a configureWithTransparentBackground];
        a.backgroundEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark];
        bar.standardAppearance = a;
        bar.scrollEdgeAppearance = a;
    }
    bar.items = @[
        [self barItem:NSLocalizedString(@"Esc", nil)  key:WineKeyEsc],
        [self barItem:NSLocalizedString(@"Tab", nil)  key:WineKeyTab],
        [self barItem:NSLocalizedString(@"Ctrl", nil) key:WineKeyCtrl],
        [self barItem:NSLocalizedString(@"Alt", nil)  key:WineKeyAlt],
        gap,
        [self barItem:@"←" key:WineKeyLeft],
        [self barItem:@"↑" key:WineKeyUp],
        [self barItem:@"↓" key:WineKeyDown],
        [self barItem:@"→" key:WineKeyRight],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                      target:nil action:nil],
        ({
            UIImage *img = [UIImage systemImageNamed:@"keyboard.chevron.compact.down"];
            UIBarButtonItem *it = img
                ? [[UIBarButtonItem alloc] initWithImage:img style:UIBarButtonItemStyleDone
                                                  target:self action:@selector(hideKeyboard)]
                : [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Hide", nil)
                                                   style:UIBarButtonItemStyleDone
                                                  target:self action:@selector(hideKeyboard)];
            it.accessibilityLabel = NSLocalizedString(@"Hide keyboard", nil);
            it;
        }),
    ];
    _keyBar = bar;
    return bar;
}

- (void)onBarKey:(UIBarButtonItem *)item
{
    [self pressSpecial:(WineSpecialKey)(item.tag - 1)];
    [self refreshKeyboardBar];
}

/* Sticky modifiers are invisible otherwise: Ctrl looks identical armed and
 * not, and the difference only shows up two keystrokes later. */
- (void)refreshKeyboardBar
{
    for (UIBarButtonItem *item in _keyBar.items)
    {
        NSInteger key = item.tag - 1;
        BOOL on = (key == WineKeyCtrl && _ctrl) || (key == WineKeyAlt && _alt);

        if (item.tag && (key == WineKeyCtrl || key == WineKeyAlt))
            item.style = on ? UIBarButtonItemStyleDone : UIBarButtonItemStylePlain;
    }
}

- (void)hideKeyboard
{
    [_keys resignFirstResponder];
}

/* A plain arrow, drawn rather than shipped as an asset. */
- (UIImage *)cursorImage
{
    CGSize size = CGSizeMake( 18, 24 );
    UIGraphicsBeginImageContextWithOptions( size, NO, 0 );
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGPoint pts[] = { {1,1}, {1,18}, {5.5,14}, {8.5,21}, {11.5,19.5}, {8.5,13}, {14,13} };

    CGContextBeginPath( c );
    CGContextAddLines( c, pts, sizeof(pts)/sizeof(pts[0]) );
    CGContextClosePath( c );
    CGContextSetFillColorWithColor( c, UIColor.whiteColor.CGColor );
    CGContextFillPath( c );

    CGContextBeginPath( c );
    CGContextAddLines( c, pts, sizeof(pts)/sizeof(pts[0]) );
    CGContextClosePath( c );
    CGContextSetStrokeColorWithColor( c, UIColor.blackColor.CGColor );
    CGContextSetLineWidth( c, 1.0 );
    CGContextStrokePath( c );

    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

- (void)positionCursor
{
    /* The hotspot is the tip, at the image's top-left. */
    _cursor.frame = CGRectMake( _cursorPos.x, _cursorPos.y, 18, 24 );
    _cursor.hidden = !_trackpad;
}

- (void)setPointerMode:(WinePointerMode)mode
{
    _pointerMode = mode;
    _trackpad = (mode == WinePointerTrackpad);
    _lookCarry = CGPointZero;
    [self positionCursor];
}

/* Move the Windows cursor to wherever ours is. Silently does nothing when the
 * point is over no window: warping to a corner is worse than not moving. */
- (void)syncCursorTo:(CGPoint)p
{
    int wx = 0, wy = 0;
    UIView *root = self.superview ?: self;

    CGPoint rp = [self convertPoint:p toView:root];
    int mapped;

    /* Counted before the early return on purpose. Counting after it made g=0
     * mean either "no touch arrived" or "the driver symbol is NULL", which are
     * the two things this counter exists to tell apart. */
    wine_input_gestures++;
    if (!drv_move) return;
    mapped = wine_surface_view_to_screen( rp.x, rp.y, &wx, &wy );
    {
        /* Two silent gates stack here -- a NULL drv_move and a point that maps
         * to no window -- and both look identical from the outside. Report the
         * first few so the dead one identifies itself. */
        static int n;
        if (n < 8) {
            n++;
            if (mapped)
                NSLog( @"[input] cursor view(%.0f,%.0f) -> screen(%d,%d)", rp.x, rp.y, wx, wy );
            else
                NSLog( @"[input] cursor view(%.0f,%.0f) -> NO WINDOW at that point",
                       rp.x, rp.y );
        }
    }
    if (mapped)
    {
        wine_input_sent++;
        wine_input_last_x = wx;
        wine_input_last_y = wy;
        drv_move( wx, wy );
    }
    else wine_input_unmapped++;
}

- (void)clampCursor
{
    if (_cursorPos.x < 0) _cursorPos.x = 0;
    if (_cursorPos.y < 0) _cursorPos.y = 0;
    if (_cursorPos.x > self.bounds.size.width  - 2) _cursorPos.x = self.bounds.size.width  - 2;
    if (_cursorPos.y > self.bounds.size.height - 2) _cursorPos.y = self.bounds.size.height - 2;
}

- (void)onPan:(UIPanGestureRecognizer *)g
{
    CGPoint t = [g translationInView:self];
    [g setTranslation:CGPointZero inView:self];

    if (_pointerMode == WinePointerLook)
    {
        /* Whole pixels go to the driver; the fraction carries to the next
         * event so slow turns are not lost to rounding. */
        CGFloat gain = (self.lookSensitivity > 0 ? self.lookSensitivity : 1.0) * self.contentScaleFactor;
        int dx, dy;

        if (!drv_move_rel) return;
        _lookCarry.x += t.x * gain;
        _lookCarry.y += t.y * gain;
        dx = (int)_lookCarry.x;
        dy = (int)_lookCarry.y;
        _lookCarry.x -= dx;
        _lookCarry.y -= dy;
        if (dx || dy)
        {
            wine_input_sent++;
            drv_move_rel( dx, dy );
        }
        return;
    }

    if (_trackpad)
    {
        /* Slight acceleration: slow drags stay precise, fast ones cross the
         * screen without several strokes. */
        CGFloat speed = hypot( t.x, t.y );
        CGFloat gain = speed > 12 ? 1.9 : 1.1;

        _cursorPos.x += t.x * gain;
        _cursorPos.y += t.y * gain;
        [self clampCursor];
        [self positionCursor];
        [self syncCursorTo:_cursorPos];
    }
    else
    {
        _cursorPos = [g locationInView:self];
        [self syncCursorTo:_cursorPos];
    }
}

- (void)onTap:(UITapGestureRecognizer *)g
{
    if (_pointerMode == WinePointerLook)
    {
        if (!drv_button) return;
        drv_button( 0, 1 );
        drv_button( 0, 0 );
        return;
    }
    if (!_trackpad) { _cursorPos = [g locationInView:self]; [self positionCursor]; }
    [self syncCursorTo:_cursorPos];
    if (!drv_button) return;
    drv_button( 0, 1 );
    drv_button( 0, 0 );
}

- (void)onTwoTap:(UITapGestureRecognizer *)g
{
    [self syncCursorTo:_cursorPos];
    if (!drv_button) return;
    drv_button( 1, 1 );
    drv_button( 1, 0 );
}

- (void)onHold:(UILongPressGestureRecognizer *)g
{
    if (!drv_button) return;

    if (g.state == UIGestureRecognizerStateBegan)
    {
        if (!_trackpad) { _cursorPos = [g locationInView:self]; [self positionCursor]; }
        [self syncCursorTo:_cursorPos];
        drv_button( 0, 1 );
    }
    else if (g.state == UIGestureRecognizerStateEnded ||
             g.state == UIGestureRecognizerStateCancelled)
        drv_button( 0, 0 );
}

- (void)onScroll:(UIPanGestureRecognizer *)g
{
    CGPoint t = [g translationInView:self];

    if (!drv_wheel) return;
    /* ~40 points per notch, so a normal flick is a few lines rather than a
     * page. Sign follows the platform convention: dragging content up scrolls
     * down. */
    if (fabs( t.y ) >= 40)
    {
        drv_wheel( (t.y > 0 ? 1 : -1) * WHEEL_DELTA, 0 );
        [g setTranslation:CGPointZero inView:self];
    }
    else if (fabs( t.x ) >= 40)
    {
        drv_wheel( (t.x > 0 ? -1 : 1) * WHEEL_DELTA, 1 );
        [g setTranslation:CGPointZero inView:self];
    }
}

- (void)onPinch:(UIPinchGestureRecognizer *)g
{
    CGPoint c = [g locationInView:self];

    if (g.state == UIGestureRecognizerStateBegan)
    {
        _panStart = c;
        g.scale = 1.0;
        return;
    }
    if (g.state != UIGestureRecognizerStateChanged) return;

    wine_surface_desktop_zoom( g.scale, c.x - _panStart.x, c.y - _panStart.y );
    _panStart = c;
    g.scale = 1.0;      /* incremental: the tool applies deltas, not totals */
}

- (void)resetZoom
{
    wine_surface_desktop_reset();
}

/* Gestures coexist: a two-finger scroll must not be starved by the one-finger
 * pan, and pinch runs alongside both. */
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b
{
    return YES;
}

/* ---- keyboard ---------------------------------------------------------- */

- (void)sendVkey:(int)vk
{
    [self sendPulse:(struct ios_key_pulse){ (uint16_t)vk, 0 }];
}

/* One key, or one character, with the sticky modifiers added. */
- (void)sendPulse:(struct ios_key_pulse)pulse
{
    if (!drv_key) return;
    wine_input_sent++;
    { static int n; if (n < 8) { n++; NSLog( @"[input] key vk=%d mods=%d drv_key=%p", pulse.vk, pulse.mods, drv_key ); } }
    if (!(pulse.mods & 8)) pulse.mods |= (_ctrl ? 1 : 0) | (_alt ? 2 : 0);
    const char *mode = getenv("KITSUNE_GAME_INPUT");
    if (!mode || !atoi(mode)) {
        KitsunePulseEmit(pulse, 1, drv_key, drv_unicode);
        KitsunePulseEmit(pulse, 0, drv_key, drv_unicode);
    } else if (KitsunePulsePush(&_keyPulses, pulse.vk, pulse.mods)) {
        KitsunePulseTick(&_keyPulses, (uint64_t)(CACurrentMediaTime() * 1000), drv_key, drv_unicode);
        dispatch_source_set_timer(_keyPulseTimer, DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC, NSEC_PER_MSEC);
    }
    else NSLog(@"[input] key pulse queue full; key %d not queued", pulse.vk);
    _ctrl = _alt = NO;   /* sticky modifiers: one keypress each */
}

- (void)insertText:(NSString *)text
{
    for (NSUInteger i = 0; i < text.length; i++)
    {
        unichar c = [text characterAtIndex:i];

        if (c == '\n' || c == '\r') { [self sendVkey:VK_RETURN]; continue; }
        if (c == '\t') { [self sendVkey:VK_TAB]; continue; }

        /* A modifier only means something with a virtual key, so Ctrl+C goes
         * through the VK path; plain text goes as Unicode, which is what makes
         * accents and non-Latin layouts work without a layout table. */
        if ((_ctrl || _alt) && c < 128)
        {
            [self sendVkey:toupper( c )];
            continue;
        }
        /* Game mode queues every character, keys and text alike, in order. */
        const char *mode = getenv("KITSUNE_GAME_INPUT");
        if (mode && atoi(mode)) { [self sendPulse:KitsuneGameTextPulse(c)]; continue; }
        if (drv_unicode) { drv_unicode( c, 1 ); drv_unicode( c, 0 ); }
    }
}

/* Characters arrive here; the field is kept empty so it never scrolls or
 * shows a caret of its own. */
- (BOOL)textField:(UITextField *)tf
        shouldChangeCharactersInRange:(NSRange)range
        replacementString:(NSString *)text
{
    if (!text.length) [self sendVkey:VK_BACK];       /* backspace */
    else [self insertText:text];
    tf.text = @" ";
    return NO;
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf
{
    [self sendVkey:VK_RETURN];
    return NO;
}

- (void)toggleKeyboard
{
    if (_keys.isFirstResponder) [_keys resignFirstResponder];
    else                        [_keys becomeFirstResponder];
}

- (void)pressSpecial:(WineSpecialKey)key
{
    switch (key)
    {
    case WineKeyEsc:   [self sendVkey:VK_ESCAPE]; break;
    case WineKeyTab:   [self sendVkey:VK_TAB]; break;
    case WineKeyUp:    [self sendVkey:VK_UP]; break;
    case WineKeyDown:  [self sendVkey:VK_DOWN]; break;
    case WineKeyLeft:  [self sendVkey:VK_LEFT]; break;
    case WineKeyRight: [self sendVkey:VK_RIGHT]; break;
    case WineKeyCtrl:  _ctrl = !_ctrl; break;
    case WineKeyAlt:   _alt = !_alt; break;
    }
}

- (BOOL)ctrlHeld { return _ctrl; }
- (BOOL)altHeld  { return _alt; }

@end

#import "wine_boot.h"
#include <unistd.h>

static void remote_run_line( NSString *line )
{
    NSArray<NSString *> *w = [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSMutableArray<NSString *> *a = [NSMutableArray array];
    for (NSString *s in w) if (s.length) [a addObject:s];
    if (!a.count || [a[0] hasPrefix:@"#"]) return;
    NSString *c = a[0].lowercaseString;
    int x = a.count > 1 ? a[1].intValue : 0, y = a.count > 2 ? a[2].intValue : 0;

    if ([c isEqualToString:@"sleep"]) { usleep( (useconds_t)x * 1000 ); return; }
    if (!drv_move || !drv_button) return;
    if ([c isEqualToString:@"move"]) { drv_move( x, y ); wine_input_last_x = x; wine_input_last_y = y; }
    else if ([c isEqualToString:@"click"] || [c isEqualToString:@"rclick"] || [c isEqualToString:@"dclick"])
    {
        int b = [c isEqualToString:@"rclick"] ? 1 : 0, n = [c isEqualToString:@"dclick"] ? 2 : 1;
        drv_move( x, y ); usleep( 60000 );
        for (int i = 0; i < n; i++) { drv_button( b, 1 ); usleep( 70000 ); drv_button( b, 0 ); usleep( 90000 ); }
        wine_input_last_x = x; wine_input_last_y = y;
    }
    else if ([c isEqualToString:@"down"]) drv_button( 0, 1 );
    else if ([c isEqualToString:@"up"]) drv_button( 0, 0 );
    else if ([c isEqualToString:@"wheel"] && drv_wheel) drv_wheel( x, 0 );
    else if ([c isEqualToString:@"key"] && drv_key) { drv_key( x, 0, 1 ); usleep( 50000 ); drv_key( x, 0, 0 ); }
    else if ([c isEqualToString:@"text"] && drv_unicode)
    {
        NSString *t = [line substringFromIndex:[line rangeOfString:a[1]].location];
        for (NSUInteger i = 0; i < t.length; i++)
        {
            unichar ch = [t characterAtIndex:i];
            drv_unicode( ch, 1 ); usleep( 30000 ); drv_unicode( ch, 0 ); usleep( 30000 );
        }
    }
    wine_input_sent++;
}

__attribute__((constructor))
static void remote_input_start(void)
{
    dispatch_async( dispatch_get_global_queue( QOS_CLASS_UTILITY, 0 ), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        for (;;)
        {
            usleep( 300000 );
            @autoreleasepool {
                NSString *docs = KitsunePersistentDocuments();
                if (!docs) continue;
                NSString *src = [docs stringByAppendingPathComponent:@"remote-input.txt"];
                if (![fm fileExistsAtPath:src]) continue;
                NSString *run = [docs stringByAppendingPathComponent:@"remote-input.running"];
                NSString *done = [docs stringByAppendingPathComponent:@"remote-input.done"];
                [fm removeItemAtPath:run error:nil];
                if (![fm moveItemAtPath:src toPath:run error:nil]) continue;
                NSString *text = [NSString stringWithContentsOfFile:run encoding:NSUTF8StringEncoding error:nil];
                for (NSString *line in [text componentsSeparatedByString:@"\n"])
                    remote_run_line( [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] );
                [fm removeItemAtPath:done error:nil];
                [fm moveItemAtPath:run toPath:done error:nil];
                NSLog( @"[kitsune] remote-input: replayed %@", run.lastPathComponent );
            }
        }
    });
}

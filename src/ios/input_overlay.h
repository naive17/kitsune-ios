
#ifndef KITSUNE_INPUT_OVERLAY_H
#define KITSUNE_INPUT_OVERLAY_H

#import <UIKit/UIKit.h>

typedef enum {
    WineKeyEsc, WineKeyTab,
    WineKeyUp, WineKeyDown, WineKeyLeft, WineKeyRight,
    WineKeyCtrl, WineKeyAlt,
} WineSpecialKey;

typedef NS_ENUM(NSInteger, WinePointerMode) {
    WinePointerTouch = 0,    /* the cursor jumps under the finger */
    WinePointerTrackpad,     /* the finger drags the cursor by a delta */
    WinePointerLook,         /* relative motion for cameras; no cursor */
};

@interface WineInputOverlay : UIView

@property (nonatomic) WinePointerMode pointerMode;
/* Pixels of relative motion per point of finger travel in look mode. */
@property (nonatomic) CGFloat lookSensitivity;

- (void)toggleKeyboard;
- (void)pressSpecial:(WineSpecialKey)key;
- (void)resetZoom;

/* Sticky modifiers: they apply to the next key and then clear. */
- (BOOL)ctrlHeld;
- (BOOL)altHeld;

@end

#endif /* KITSUNE_INPUT_OVERLAY_H */

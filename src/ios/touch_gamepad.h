#import <UIKit/UIKit.h>

/* An on-screen Xbox-style controller whose state joins controller slot 0.
 * Touches outside its controls reach the views below it. Hiding it
 * disconnects it. */
@interface WineTouchGamepad : UIView
- (void)releaseAll;
@end

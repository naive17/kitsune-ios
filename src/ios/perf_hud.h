/* In-session readout: frames per second and memory headroom. */
#ifndef IOSWINE_PERF_HUD_H
#define IOSWINE_PERF_HUD_H

#import <UIKit/UIKit.h>

@interface WinePerfHUD : UIView
/* Starts sampling while visible; stops when hidden or removed. */
- (void)setVisible:(BOOL)visible;
@end

#endif

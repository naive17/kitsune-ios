/* A sheet for work that takes time: title, stage, bar. It closes itself when
 * the work succeeds, and stays, with Done, only to show an error. */
#ifndef KITSUNE_PROGRESS_VC_H
#define KITSUNE_PROGRESS_VC_H

#import <UIKit/UIKit.h>

@interface WineProgressVC : UIViewController
/* fraction < 0 shows an indeterminate bar. Main thread. */
- (void)setStage:(NSString *)stage detail:(NSString *)detail fraction:(double)fraction;
- (void)finish;
- (void)failWithMessage:(NSString *)message;
+ (instancetype)presentFrom:(UIViewController *)host title:(NSString *)title;
@end

#endif

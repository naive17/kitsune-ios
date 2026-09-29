/* Boot state shared with the launcher screens. Main thread only. */
#ifndef IOSWINE_BOOT_STATUS_H
#define IOSWINE_BOOT_STATUS_H

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, WineBootPhase) {
  WineBootPhasePreparing,   /* runtime and prefix checks running */
  WineBootPhaseNeedsJIT,    /* waiting for the user to start something */
  WineBootPhaseWaitingJIT,  /* StikDebug opened, polling for the grant */
  WineBootPhaseReady,       /* programs can be launched */
  WineBootPhaseLaunching,   /* a program has been handed to Wine */
  WineBootPhaseFailed,      /* message says why; details on the boot screen */
  WineBootPhaseRunning,     /* programs run; more can start alongside */
};

extern NSNotificationName const WineBootStatusDidChangeNotification;

@interface WineBootStatus : NSObject
@property(nonatomic, readonly) WineBootPhase phase;
@property(nonatomic, readonly, copy) NSString *message;
/* Fraction of a long step done, or -1 when there is nothing to measure. */
@property(nonatomic, readonly) double progress;
+ (instancetype)shared;
/* Any thread; the change is posted on the main thread. A new phase clears the
 * progress. */
- (void)setPhase:(WineBootPhase)phase message:(NSString *)message;
- (void)setProgress:(double)fraction;
@end

#endif

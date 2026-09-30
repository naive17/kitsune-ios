/*
 * Power modes for a running program.
 *
 * Two levers, both live: the QoS class of Wine's guest threads (a thread adopts
 * a change at its next wait, since iOS lets a thread change only its own QoS),
 * and a minimum interval between presented frames, applied in winemetal.
 * Battery mode is chosen automatically under Low Power Mode or a serious
 * thermal state, which otherwise ends with iOS backgrounding and killing the
 * app.
 */
#ifndef KITSUNE_POWER_H
#define KITSUNE_POWER_H

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, WinePowerMode) {
  WinePowerBalanced = 0,     /* system default QoS, the tested baseline */
  WinePowerPerformance = 1,  /* user-interactive QoS for guest threads */
  WinePowerBattery = 2,      /* utility QoS and at most 30 presents per second */
};

extern NSNotificationName const WinePowerDidChangeNotification;

@interface WinePower : NSObject
+ (instancetype)shared;
/* The user's choice, persisted. */
@property(nonatomic) WinePowerMode userMode;
/* What is in force after Low Power Mode and thermal state are considered. */
@property(nonatomic, readonly) WinePowerMode effectiveMode;
- (void)start;
@end

#endif

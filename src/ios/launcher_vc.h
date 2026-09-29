/*
 * The launcher: Library, Bottles and Settings tabs. It decides what runs and
 * hands an argv to the boot controller, which owns the one-way transition
 * into Wine.
 */
#ifndef IOS_LAUNCHER_VC_H
#define IOS_LAUNCHER_VC_H

#import <UIKit/UIKit.h>

@class WineLauncherVC;

@protocol WineLauncherDelegate <NSObject>
/* Run `argv` (argv[0] is "wine") from `cwd` in `bottle` (nil: default). */
- (void)launcher:(WineLauncherVC *)vc
       runArgv:(NSArray<NSString *> *)argv
    workingDir:(NSString *)cwd
        bottle:(NSString *)bottle
           gui:(BOOL)gui
         label:(NSString *)label;
/* Start Steam and, when `appID` is set, launch that title through it. */
- (void)launcher:(WineLauncherVC *)vc playSteamApp:(NSString *)appID named:(NSString *)name;
/* Show the boot screen with its details log. */
- (void)launcherShowBootDetails:(WineLauncherVC *)vc;
/* Ask StikDebug for JIT without choosing a program. */
- (void)launcherEnableJIT:(WineLauncherVC *)vc;
@end

@interface WineLauncherVC : UITabBarController
@property(nonatomic, weak) id<WineLauncherDelegate> launcherDelegate;
- (void)refreshAll;
- (void)report:(NSString *)title message:(NSString *)msg;
@end

/* Shared by the tabs: a header cell reflecting WineBootStatus. */
@interface WineStatusHeader : UIView
- (void)update;
@end

#endif

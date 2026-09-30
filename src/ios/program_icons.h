/* Icons for the launcher: a program's own icon from its executable, and a
 * Steam game's header art from the Steam client's cache. Loaded off the main
 * thread and kept in memory and under Caches/icons. */
#ifndef KITSUNE_PROGRAM_ICONS_H
#define KITSUNE_PROGRAM_ICONS_H

#import <UIKit/UIKit.h>

extern const CGSize WineProgramIconSize;
extern const CGSize WineSteamArtSize;

@interface WineIcons : NSObject
+ (instancetype)shared;
/* The icon when it is already loaded. Otherwise nil, and `ready` runs on the
 * main queue once loading has finished, whether or not an icon was found. */
- (UIImage *)iconForExecutable:(NSString *)path ready:(void (^)(void))ready;
- (UIImage *)artForSteamApp:(NSString *)appID steamRoot:(NSString *)root ready:(void (^)(void))ready;
@end

/* Header art in the Steam client's cache, in the per-app layout or the older
 * flat one; nil when Steam has not fetched it. */
NSString *KitsuneSteamArtPath(NSString *steamRoot, NSString *appID);

#endif

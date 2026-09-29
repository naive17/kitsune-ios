/* The Steam install sheet: what it installs, from where and how big, with the
 * packages one tap away, then the install's progress. */
#ifndef IOSWINE_STEAM_INSTALL_VC_H
#define IOSWINE_STEAM_INSTALL_VC_H

#import <UIKit/UIKit.h>

@interface WineSteamInstallVC : UITableViewController
/* onInstalled runs after a successful install. */
+ (void)presentFrom:(UIViewController *)host onInstalled:(void (^)(void))onInstalled;
@end

#endif

/* Bottles tab: list, create, inspect, delete. */
#ifndef IOSWINE_BOTTLES_VC_H
#define IOSWINE_BOTTLES_VC_H

#import <UIKit/UIKit.h>

@interface WineBottlesVC : UITableViewController
- (void)refresh;
@end

@interface WineBottleDetailVC : UITableViewController
- (instancetype)initWithBottle:(NSString *)name;
@end

#endif

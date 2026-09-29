#ifndef IOS_APP_LIBRARY_H
#define IOS_APP_LIBRARY_H

#import <Foundation/Foundation.h>

#include "pe_info.h"

typedef NS_ENUM(NSInteger, WineAppOrigin) {
  WineAppOriginImported = 0,  /* a ZIP or EXE the user brought in */
  WineAppOriginInstalled,     /* found in the prefix after an installer ran */
  WineAppOriginBuiltin,       /* ships in the wine tree: notepad, cmd, winecfg... */
};

@interface WineApp : NSObject
@property(nonatomic, copy)   NSString *uid;
@property(nonatomic, copy)   NSString *name;
/* Unix path to the executable, and the directory it must be launched from. */
@property(nonatomic, copy)   NSString *exePath;
@property(nonatomic, copy)   NSString *workingDir;
@property(nonatomic, assign) pe_arch arch;
@property(nonatomic, assign) pe_subsystem subsystem;
@property(nonatomic, assign) WineAppOrigin origin;
@property(nonatomic, copy)   NSString *arguments;
/* Bottle the program runs in; nil is the default prefix. */
@property(nonatomic, copy)   NSString *bottle;
@property(nonatomic, copy)   NSDate *addedAt;

/* "ARM64", "x86-64", "32-bit x86" -- what the row shows. */
- (NSString *)archLabel;
/* NO when this build has no runtime for the image; the row is then disabled
 * with a reason rather than failing after the process is gone. */
- (BOOL)runnableWithWow64:(BOOL)haveWow64;
@end

@interface WineAppLibrary : NSObject

+ (instancetype)shared;

/* Documents/Apps. Created on first use. */
+ (NSString *)appsRoot;

@property(nonatomic, readonly) NSArray<WineApp *> *apps;

- (void)load;
- (void)save;

- (NSArray<WineApp *> *)importFileAtURL:(NSURL *)url
                               progress:(void (^)(NSString *line))progress
                                  error:(NSString **)err;

- (NSUInteger)rescanInstalledInPrefix:(NSString *)prefix;
- (NSUInteger)rescanBuiltinsInTree:(NSString *)treeRoot;

- (void)remove:(WineApp *)app;

@end

#endif

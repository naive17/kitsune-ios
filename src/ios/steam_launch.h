/* Phone-only Steam launches: the request, its checks and the JIT hand-off. */
#ifndef KITSUNE_STEAM_LAUNCH_H
#define KITSUNE_STEAM_LAUNCH_H
#import <Foundation/Foundation.h>
#include "launch_request.h"
#include "launch_profile.h"
#include "steam_library.h"

/* Validate a Steam request against the installed tree. `appID` nil launches
 * the client alone; otherwise the title's directory must exist under
 * steamapps/common (from its manifest), so a half-installed game is refused
 * before the process is handed over. */
static inline NSDictionary *KitsuneSteamRequest(NSString *appID, KitsuneLaunchOptions options,
                                         NSString *docs, NSString **error) {
  if (!KitsuneSteamRoot(docs)) {
    if (error) *error = NSLocalizedString(@"Steam is not installed in this app's library (Documents/Apps/Steam/steam.exe).", nil);
    return nil;
  }
  if (appID.length) {
    NSDictionary *found = nil;
    for (NSDictionary *g in KitsuneSteamGames(KitsuneSteamRoot(docs)))
      if ([g[@"appid"] isEqualToString:appID]) { found = g; break; }
    if (!found) {
      if (error) *error = [NSString stringWithFormat:NSLocalizedString(@"Steam app %@ is not installed in this library.", nil), appID];
      return nil;
    }
    if (![found[@"installed"] boolValue]) {
      if (error) *error = [NSString stringWithFormat:NSLocalizedString(@"%@ is not fully installed yet. Finish it in Steam first.", nil), found[@"name"]];
      return nil;
    }
  }
  return KitsuneValidateLaunchRequest(KitsuneSteamLaunchRequest(appID, options), docs, error);
}

/* The JSON that goes into Documents/launch-request.json: the unvalidated
 * request (relative exe path), which the boot path validates again. */
static inline NSData *KitsuneSteamRequestData(NSString *appID, KitsuneLaunchOptions options) {
  return [NSJSONSerialization dataWithJSONObject:KitsuneSteamLaunchRequest(appID, options)
                                         options:NSJSONWritingPrettyPrinted error:nil];
}

/* StikDebug's enable-jit URL, wrapped for LiveContainer and bare. With a pid
 * StikDebug attaches to that process; without one it launches the app. */
static inline NSArray<NSURL *> *KitsuneStikDebugURLs(NSString *bundle, NSString *pid, NSData *script) {
  NSURLComponents *inner = [NSURLComponents new];
  inner.scheme = @"stikjit";
  inner.host = @"enable-jit";
  NSMutableArray<NSURLQueryItem *> *query = [NSMutableArray arrayWithObject:[NSURLQueryItem queryItemWithName:@"bundle-id" value:bundle]];
  if (pid) [query addObject:[NSURLQueryItem queryItemWithName:@"pid" value:pid]];
  [query addObject:[NSURLQueryItem queryItemWithName:@"script-data" value:[script base64EncodedStringWithOptions:0]]];
  inner.queryItems = query;
  inner.percentEncodedQuery = [inner.percentEncodedQuery stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"];
  NSURLComponents *outer = [NSURLComponents new];
  outer.scheme = @"livecontainer";
  outer.host = @"open-url";
  outer.queryItems = @[[NSURLQueryItem queryItemWithName:@"url" value:
      [[inner.URL.absoluteString dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]]];
  outer.percentEncodedQuery = [outer.percentEncodedQuery stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"];
  return @[outer.URL, inner.URL];
}

/* JIT for the running process `pid`. */
static inline NSArray<NSURL *> *KitsuneJITURLs(NSString *bundle, int pid, NSData *script) {
  if (!bundle.length || pid <= 0 || !script.length) return @[];
  return KitsuneStikDebugURLs(bundle, [NSString stringWithFormat:@"%d", pid], script);
}

/* A new instance of the app under JIT, for a restart: StikDebug launches it
 * once the running one has exited. */
static inline NSArray<NSURL *> *KitsuneRelaunchURLs(NSString *bundle, NSData *script) {
  if (!bundle.length || !script.length) return @[];
  return KitsuneStikDebugURLs(bundle, nil, script);
}
#endif

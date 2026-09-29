/* Boot Wine in-process on iOS. See wine_boot.m. */
#ifndef IOS_WINE_BOOT_H
#define IOS_WINE_BOOT_H
#import <Foundation/Foundation.h>
typedef void (^WineBootLog)(NSString *line);
NSString *IOSWinePersistentDocuments(void);
NSString *WineTreeRoot(void);
NSString *WineUnixRoot(void);
NSString *WineLogPath(void);
/* The same path as a plain C string, resolved once. Use this from any thread
 * that runs while Wine is live: WineLogPath() allocates through Foundation and
 * that faults on device once Wine owns the address space. See wine_boot.m. */
const char *WineLogPathC(void);
/* The WINEPREFIX this app boots. */
NSString *WineBootPrefix(void);
/* The bottle to boot, chosen before Wine starts; nil is the default prefix. */
BOOL WineBootSelectBottle(NSString *name);
/* Where DXMT keeps its on-disk DXBC->AIR shader cache. Regenerable, so it
 * lives in Caches rather than Documents. See configure_environment(). */
NSString *WineShaderCacheRoot(void);
void WineBootSampleGuest(char *out, size_t outlen);
/* One line per host thread: mach run state, Wine pid/tid (from the TEB in
 * x28), pc (named), lr, sp, x0 and the frame-pointer return chain. Reads are
 * fault-safe and nothing is suspended. Lines go to emit(). */
void WineBootDumpThreads(const char *tag, void (*emit)(const char *));
/* Address-space map: holes >= 64MB and mappings >= 256MB, coalesced. */
void WineBootDumpVM(const char *tag, void (*emit)(const char *));
/* IMAGE lines with the bases of libsystem/libdyld/app for symbolising dumps. */
void WineBootLogImageBases(void (*emit)(const char *));
/* MAP_FIXED probes into the OS-reserved bands; run before Wine only. */
void WineBootProbeFixedMap(void (*emit)(const char *));
/* Copy src to dst whole (for pulling a growing log). */
void WineBootSnapshotLog(const char *src, const char *dst);
/* dlopen_preflight every .so in dir; one PREFLIGHT line each with dyld's reason. */
void WineBootPreflightUnixLibs(const char *dir, void (*emit)(const char *));

/* Non-zero once the guest program has exited and handed the process back. */
int WineBootExited(int *status);
BOOL WineTreeInstalled(void);
/* Runs __wine_main; does NOT return on success. Returns 0 with err set on
 * failure to get that far. */
int WineBootRun(NSArray<NSString *> *args, WineBootLog log, char *err, size_t errlen);
#endif

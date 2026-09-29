/*
 * Steam installation from Valve's client packages.
 *
 * The client is the set of win64 update packages the Steam bootstrapper
 * itself downloads: a KeyValues manifest listing each package as a ZIP and,
 * for most, an LZMA-compressed VZ copy, with sizes and SHA-256. Fetching the
 * files the updater fetches, extracting them into Apps/Steam, keeping them in
 * its package folder under the names it checks, and writing the two files its
 * updater keeps there (the manifest, and an index of every installed file)
 * gives a client that Steam's own updater accepts: it starts without
 * downloading or unpacking itself again, self-updates and logs in. The bottle
 * needs Windows 10 reported, the Common Controls v6 assembly and the RSA
 * crypto providers, which wine.inf would register through child processes
 * this port does not run; they are written directly.
 */
#ifndef IOSWINE_STEAM_INSTALL_H
#define IOSWINE_STEAM_INSTALL_H

#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <time.h>
#include "bottles.h"
#include "steam_library.h"

#define IOSWINE_STEAM_CLIENT_BASE @"https://client-update.akamai.steamstatic.com/"
#define IOSWINE_STEAM_MANIFEST @"steam_client_win64"

/* What a package of the client holds, in a few words. */
static inline NSString *IOSWineSteamPackageTitle(NSString *name) {
  NSDictionary<NSString *, NSString *> *titles = @{
    @"steam_win64": NSLocalizedString(@"Steam launcher", nil),
    @"bins_win64": NSLocalizedString(@"Steam client", nil),
    @"bins_cef_win64": NSLocalizedString(@"Web browser engine", nil),
    @"bins_webhelpers_win64": NSLocalizedString(@"Web helper", nil),
    @"bins_codecs_win64": NSLocalizedString(@"Media codecs", nil),
    @"bins_misc_win64": NSLocalizedString(@"Support libraries", nil),
    @"bins_hardware_win64": NSLocalizedString(@"Controller support", nil),
    @"bins_hardware_all": NSLocalizedString(@"Controller support files", nil),
    @"steamui_websrc_all": NSLocalizedString(@"Steam interface", nil),
    @"steamui_websrc_sounds_all": NSLocalizedString(@"Interface sounds", nil),
    @"steamui_websrc_movies_all": NSLocalizedString(@"Interface videos", nil),
    @"public_all": NSLocalizedString(@"Shared files", nil),
    @"resources_all": NSLocalizedString(@"Images", nil),
    @"resources_hidpi_all": NSLocalizedString(@"High-resolution images", nil),
    @"resources_misc_all": NSLocalizedString(@"Other resources", nil),
    @"strings_all": NSLocalizedString(@"Translations", nil),
    @"strings_en_all": NSLocalizedString(@"English text", nil),
    @"tenfoot_images_all": NSLocalizedString(@"Big Picture images", nil),
  };
  return titles[name] ?: name;
}

/* Packages of the win64 client from the manifest text, largest download
 * first: name, title, the zip's file, sha2 and size, and when the manifest
 * offers one the VZ (LZMA) copy's vz and sha2vz. download, downloadSha2 and
 * downloadSize describe the file fetched: the VZ when there is one, as
 * Steam's updater does, since that is the file it looks for in package/.
 * order is the package's place in the manifest, which decides between two
 * packages holding the same path. nil when the manifest is not what the
 * bootstrapper ships. */
static inline NSArray<NSDictionary *> *IOSWineSteamPackages(NSString *manifestText, NSString **version) {
  NSDictionary *root = IOSWineParseKeyValues(manifestText);
  NSDictionary *win64 = [root[@"win64"] isKindOfClass:NSDictionary.class] ? root[@"win64"] : nil;
  if (!win64 && [root[@"version"] isKindOfClass:NSString.class]) win64 = root;   /* already unwrapped */
  NSString *ver = win64[@"version"];
  NSCharacterSet *nonDigits = NSCharacterSet.decimalDigitCharacterSet.invertedSet;
  if (![ver isKindOfClass:NSString.class] || [ver rangeOfCharacterFromSet:nonDigits].location != NSNotFound)
    return nil;
  NSRegularExpression *fileRe = [NSRegularExpression regularExpressionWithPattern:@"^[A-Za-z0-9_.-]+$" options:0 error:nil];
  NSRegularExpression *shaRe = [NSRegularExpression regularExpressionWithPattern:@"^[a-f0-9]{64}$" options:0 error:nil];
  BOOL (^matches)(NSRegularExpression *, id) = ^BOOL(NSRegularExpression *re, id value) {
    return [value isKindOfClass:NSString.class] &&
           [re firstMatchInString:value options:0 range:NSMakeRange(0, [value length])] != nil;
  };
  NSMutableArray *packages = [NSMutableArray array];
  for (NSString *name in win64) {
    NSDictionary *pkg = win64[name];
    if (![pkg isKindOfClass:NSDictionary.class]) continue;
    /* The launcher package comes in one variant per realm; outside China the
     * updater looks for steamrow's file names. */
    if ([pkg[@"steamrow"] isKindOfClass:NSDictionary.class]) pkg = pkg[@"steamrow"];
    if (![pkg[@"file"] isKindOfClass:NSString.class]) continue;
    NSString *file = pkg[@"file"], *sha = pkg[@"sha2"], *size = pkg[@"size"];
    NSString *vz = pkg[@"zipvz"], *shaVz = pkg[@"sha2vz"];
    if (!matches(fileRe, file) || !matches(shaRe, sha) || ![size isKindOfClass:NSString.class] || !size.length ||
        [size rangeOfCharacterFromSet:nonDigits].location != NSNotFound)
      return nil;
    NSUInteger order = [manifestText rangeOfString:[NSString stringWithFormat:@"\"%@\"", name]].location;
    NSMutableDictionary *entry = [@{ @"name": name, @"title": IOSWineSteamPackageTitle(name), @"order": @(order),
                                     @"file": file, @"sha2": sha,
                                     @"size": @(strtoull(size.UTF8String, NULL, 10)),
                                     @"download": file, @"downloadSha2": sha,
                                     @"downloadSize": @(strtoull(size.UTF8String, NULL, 10)) } mutableCopy];
    if (vz || shaVz) {
      /* The VZ name ends in its size: <name>.zip.vz.<sha1>_<bytes>. */
      NSString *vzSize = [vz isKindOfClass:NSString.class] ? [vz componentsSeparatedByString:@"_"].lastObject : nil;
      if (!matches(fileRe, vz) || !matches(shaRe, shaVz) || !vzSize.length ||
          [vzSize rangeOfCharacterFromSet:nonDigits].location != NSNotFound)
        return nil;
      entry[@"vz"] = vz;
      entry[@"sha2vz"] = shaVz;
      entry[@"download"] = vz;
      entry[@"downloadSha2"] = shaVz;
      entry[@"downloadSize"] = @(strtoull(vzSize.UTF8String, NULL, 10));
    }
    [packages addObject:entry];
  }
  if (!packages.count) return nil;
  [packages sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
    NSComparisonResult bySize = [b[@"downloadSize"] compare:a[@"downloadSize"]];
    return bySize != NSOrderedSame ? bySize : [a[@"name"] compare:b[@"name"]];
  }];
  if (version) *version = ver;
  return packages;
}

/* The manifest as Steam's updater saves it, package/steam_client_win64.manifest:
 * the file Valve's servers send, with Windows line endings. */
static inline NSData *IOSWineSteamSavedManifest(NSData *manifest) {
  NSMutableData *out = [NSMutableData dataWithCapacity:manifest.length + manifest.length / 16];
  const uint8_t *bytes = manifest.bytes;
  for (NSUInteger i = 0; i < manifest.length; i++) {
    if (bytes[i] == '\n' && (i == 0 || bytes[i - 1] != '\r')) [out appendBytes:"\r" length:1];
    [out appendBytes:bytes + i length:1];
  }
  return out;
}

/* The modification time Steam's extractor gives a file: the zip entry's
 * MS-DOS date and time read as UTC, plus eight hours. */
static inline int64_t IOSWineSteamFileTime(uint16_t dosDate, uint16_t dosTime) {
  struct tm t = {0};
  t.tm_year = 80 + (dosDate >> 9);
  t.tm_mon = ((dosDate >> 5) & 0xf) - 1;
  t.tm_mday = dosDate & 0x1f;
  t.tm_hour = dosTime >> 11;
  t.tm_min = (dosTime >> 5) & 0x3f;
  t.tm_sec = (dosTime & 0x1f) * 2;
  return (int64_t)timegm(&t) + 8 * 3600;
}

/* One line of Steam's install index: "path,size;mtime;crc32" with Windows
 * separators, and "folder\,-1;mtime;0" for a folder entry of a package. */
static inline NSString *IOSWineSteamIndexLine(NSString *name, BOOL isDir, uint64_t size, int64_t mtime, uint32_t crc) {
  NSString *path = [name stringByReplacingOccurrencesOfString:@"/" withString:@"\\"];
  if (isDir) return [NSString stringWithFormat:@"%@%@,-1;%lld;0", path, [path hasSuffix:@"\\"] ? @"" : @"\\", mtime];
  return [NSString stringWithFormat:@"%@,%llu;%lld;%u", path, size, mtime, crc];
}

/* Steam's install index, package/steam_client_win64.installed, which its
 * updater verifies the install against: one line per package entry, then
 * OSVER, VERSION, and the upper-case SHA-1 of everything above that line
 * taken with \n line ends. The file has Windows line ends. */
static inline NSData *IOSWineSteamInstalledIndex(NSArray<NSString *> *lines) {
  NSMutableString *text = [NSMutableString string];
  for (NSString *line in lines) [text appendFormat:@"%@\n", line];
  [text appendString:@"OSVER=16\nVERSION=3\n"];
  NSData *utf8 = [text dataUsingEncoding:NSUTF8StringEncoding];
  unsigned char digest[CC_SHA1_DIGEST_LENGTH];
  /* SHA-1 is the file's own checksum, not a security measure. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  CC_SHA1(utf8.bytes, (CC_LONG)utf8.length, digest);
#pragma clang diagnostic pop
  [text appendString:@"SHA1="];
  for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [text appendFormat:@"%02X", digest[i]];
  [text appendString:@"\n"];
  return IOSWineSteamSavedManifest([text dataUsingEncoding:NSUTF8StringEncoding]);
}

static NSString *const IOSWineRsaenhProviders =
  @"[Software\\\\Microsoft\\\\Cryptography\\\\Defaults\\\\Provider\\\\Microsoft Base Cryptographic Provider v1.0] 1790008685\n"
   "\"Image Path\"=\"C:\\\\windows\\\\system32\\\\rsaenh.dll\"\n\"Type\"=dword:00000001\n\n"
   "[Software\\\\Microsoft\\\\Cryptography\\\\Defaults\\\\Provider\\\\Microsoft Enhanced Cryptographic Provider v1.0] 1790008685\n"
   "\"Image Path\"=\"C:\\\\windows\\\\system32\\\\rsaenh.dll\"\n\"Type\"=dword:00000001\n\n"
   "[Software\\\\Microsoft\\\\Cryptography\\\\Defaults\\\\Provider\\\\Microsoft Enhanced RSA and AES Cryptographic Provider] 1790008685\n"
   "\"Image Path\"=\"C:\\\\windows\\\\system32\\\\rsaenh.dll\"\n\"Type\"=dword:00000018\n\n"
   "[Software\\\\Microsoft\\\\Cryptography\\\\Defaults\\\\Provider\\\\Microsoft Enhanced RSA and AES Cryptographic Provider (Prototype)] 1790008685\n"
   "\"Image Path\"=\"C:\\\\windows\\\\system32\\\\rsaenh.dll\"\n\"Type\"=dword:00000018\n\n"
   "[Software\\\\Microsoft\\\\Cryptography\\\\Defaults\\\\Provider\\\\Microsoft RSA SChannel Cryptographic Provider] 1790008685\n"
   "\"Image Path\"=\"C:\\\\windows\\\\system32\\\\rsaenh.dll\"\n\"Type\"=dword:0000000c\n\n"
   "[Software\\\\Microsoft\\\\Cryptography\\\\Defaults\\\\Provider\\\\Microsoft Strong Cryptographic Provider] 1790008685\n"
   "\"Image Path\"=\"C:\\\\windows\\\\system32\\\\rsaenh.dll\"\n\"Type\"=dword:00000001\n\n"
   "[Software\\\\Microsoft\\\\Cryptography\\\\Defaults\\\\Provider Types\\\\Type 001] 1790008685\n"
   "\"Name\"=\"Microsoft Enhanced Cryptographic Provider v1.0\"\n\"TypeName\"=\"RSA Full (Signature and Key Exchange)\"\n\n"
   "[Software\\\\Microsoft\\\\Cryptography\\\\Defaults\\\\Provider Types\\\\Type 012] 1790008685\n"
   "\"Name\"=\"Microsoft RSA SChannel Cryptographic Provider\"\n\"TypeName\"=\"RSA SChannel\"\n\n"
   "[Software\\\\Microsoft\\\\Cryptography\\\\Defaults\\\\Provider Types\\\\Type 024] 1790008685\n"
   "\"Name\"=\"Microsoft Enhanced RSA and AES Cryptographic Provider\"\n\"TypeName\"=\"RSA Full and AES\"\n";

#define IOSWINE_COMCTL_ASSEMBLY @"arm64_microsoft.windows.common-controls_6595b64144ccf1df_6.0.2600.2982_none_deadbeef"

static NSString *const IOSWineComctl32Manifest =
  @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
   "<assembly xmlns=\"urn:schemas-microsoft-com:asm.v1\" manifestVersion=\"1.0\">\n"
   "  <assemblyIdentity type=\"win32\" name=\"Microsoft.Windows.Common-Controls\" version=\"6.0.2600.2982\" processorArchitecture=\"arm64\" publicKeyToken=\"6595b64144ccf1df\"/>\n"
   "  <file name=\"comctl32.dll\">\n"
   "    <windowClass>Button</windowClass>\n    <windowClass>ButtonListBox</windowClass>\n    <windowClass>ComboBoxEx32</windowClass>\n"
   "    <windowClass>ComboLBox</windowClass>\n    <windowClass>ComboBox</windowClass>\n    <windowClass>Edit</windowClass>\n"
   "    <windowClass>ListBox</windowClass>\n    <windowClass>NativeFontCtl</windowClass>\n    <windowClass>ReBarWindow32</windowClass>\n"
   "    <windowClass>ScrollBar</windowClass>\n    <windowClass>Static</windowClass>\n    <windowClass>SysAnimate32</windowClass>\n"
   "    <windowClass>SysDateTimePick32</windowClass>\n    <windowClass>SysHeader32</windowClass>\n    <windowClass>SysIPAddress32</windowClass>\n"
   "    <windowClass>SysLink</windowClass>\n    <windowClass>SysListView32</windowClass>\n    <windowClass>SysMonthCal32</windowClass>\n"
   "    <windowClass>SysPager</windowClass>\n    <windowClass>SysTabControl32</windowClass>\n    <windowClass>SysTreeView32</windowClass>\n"
   "    <windowClass>ToolbarWindow32</windowClass>\n    <windowClass>msctls_hotkey32</windowClass>\n    <windowClass>msctls_progress32</windowClass>\n"
   "    <windowClass>msctls_statusbar32</windowClass>\n    <windowClass>msctls_trackbar32</windowClass>\n    <windowClass>msctls_updown32</windowClass>\n"
   "    <windowClass>tooltips_class32</windowClass>\n  </file>\n</assembly>\n";

static inline BOOL IOSWineAppendRegistry(NSString *file, NSString *marker, NSString *fragment, NSString **error) {
  NSString *current = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil];
  if (!current) {
    if (error) *error = [NSString stringWithFormat:NSLocalizedString(@"%@ is missing", nil), file.lastPathComponent];
    return NO;
  }
  if ([current containsString:marker]) return YES;
  NSString *joined = [current hasSuffix:@"\n"] ? [current stringByAppendingFormat:@"\n%@", fragment]
                                                : [current stringByAppendingFormat:@"\n\n%@", fragment];
  NSError *err = nil;
  if (![joined writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
    if (error) *error = err.localizedDescription;
    return NO;
  }
  return YES;
}

/* Make a bottle able to run Steam. Idempotent. `treeRoot` supplies
 * comctl32_v6.dll and rsaenh.dll. */
static inline BOOL IOSWinePrepareSteamBottle(NSString *bottle, NSString *treeRoot, NSString **error) {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSString *pe = [treeRoot stringByAppendingPathComponent:@"lib/wine/aarch64-windows"];
  NSString *windows = [bottle stringByAppendingPathComponent:@"drive_c/windows"];
  if (![fm fileExistsAtPath:[bottle stringByAppendingPathComponent:@"system.reg"]]) {
    if (error) *error = NSLocalizedString(@"The bottle has no registry.", nil);
    return NO;
  }
  for (NSString *dll in @[ @"comctl32_v6.dll", @"rsaenh.dll" ])
    if (![fm fileExistsAtPath:[pe stringByAppendingPathComponent:dll]]) {
      if (error) *error = [NSString stringWithFormat:NSLocalizedString(@"The runtime tree has no %@.", nil), dll];
      return NO;
    }
  if (!IOSWineAppendRegistry([bottle stringByAppendingPathComponent:@"system.reg"],
                             @"Microsoft Enhanced RSA and AES Cryptographic Provider]", IOSWineRsaenhProviders, error))
    return NO;
  if (!IOSWineAppendRegistry([bottle stringByAppendingPathComponent:@"user.reg"],
                             @"\"Version\"=\"win10\"", @"[Software\\\\Wine] 1790008685\n\"Version\"=\"win10\"\n", error))
    return NO;
  NSString *assembly = [[windows stringByAppendingPathComponent:@"winsxs"] stringByAppendingPathComponent:IOSWINE_COMCTL_ASSEMBLY];
  NSString *manifests = [windows stringByAppendingPathComponent:@"winsxs/manifests"];
  NSString *system32 = [windows stringByAppendingPathComponent:@"system32"];
  NSError *err = nil;
  for (NSString *dir in @[ assembly, manifests, system32 ])
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&err]) {
      if (error) *error = err.localizedDescription;
      return NO;
    }
  NSString *manifest = [manifests stringByAppendingPathComponent:[IOSWINE_COMCTL_ASSEMBLY stringByAppendingString:@".manifest"]];
  if (![fm fileExistsAtPath:manifest] &&
      ![IOSWineComctl32Manifest writeToFile:manifest atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
    if (error) *error = err.localizedDescription;
    return NO;
  }
  NSDictionary *copies = @{
    [assembly stringByAppendingPathComponent:@"comctl32.dll"]: [pe stringByAppendingPathComponent:@"comctl32_v6.dll"],
    [system32 stringByAppendingPathComponent:@"rsaenh.dll"]: [pe stringByAppendingPathComponent:@"rsaenh.dll"],
  };
  for (NSString *dst in copies) {
    if ([fm fileExistsAtPath:dst]) continue;
    if (![fm copyItemAtPath:copies[dst] toPath:dst error:&err]) {
      if (error) *error = err.localizedDescription;
      return NO;
    }
  }
  if (error) *error = nil;
  return YES;
}

#ifdef __OBJC__
typedef NS_ENUM(NSInteger, WineSteamStep) {
  WineSteamStepPreparing,     /* making the Steam bottle ready */
  WineSteamStepDownloading,   /* fetching a package */
  WineSteamStepUnpacking,     /* extracting a package */
  WineSteamStepFinishing,     /* moving the client into place */
};

/* Installs Steam from Valve's client packages into Documents/Apps/Steam, after
 * creating and preparing the Steam bottle. One run at a time. Callbacks arrive
 * on the main thread. */
@interface WineSteamInstaller : NSObject
+ (BOOL)isRunning;
+ (void)cancel;
/* Valve's current client: its version and packages (see IOSWineSteamPackages). */
+ (void)fetchClientInto:(NSString *)docs
             completion:(void (^)(NSString *version, NSArray<NSDictionary *> *packages, NSString *error))completion;
/* Installs the client fetchClientInto: returned. package is the index of the
 * package in step, fraction its share done, overall the whole install's.
 * error is nil on success and "Cancelled" after cancel; downloaded packages
 * are kept, so a retry resumes. */
+ (void)installIntoDocuments:(NSString *)docs
                    treeRoot:(NSString *)treeRoot
                    progress:(void (^)(WineSteamStep step, NSUInteger package, double fraction, double overall))progress
                  completion:(void (^)(NSString *error))completion;
@end
#endif

#endif

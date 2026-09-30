#import "program_icons.h"

#import <CommonCrypto/CommonDigest.h>

#include "pe_icon.h"

const CGSize WineProgramIconSize = { 36, 36 };
const CGSize WineSteamArtSize = { 64, 30 };

NSString *KitsuneSteamArtPath(NSString *steamRoot, NSString *appID) {
  NSString *cache = [steamRoot stringByAppendingPathComponent:@"appcache/librarycache"];
  NSString *perApp = [cache stringByAppendingPathComponent:appID];
  for (NSString *path in @[ [perApp stringByAppendingPathComponent:@"header.jpg"],
                            [cache stringByAppendingPathComponent:[appID stringByAppendingString:@"_header.jpg"]],
                            [perApp stringByAppendingPathComponent:@"library_600x900.jpg"],
                            [cache stringByAppendingPathComponent:[appID stringByAppendingString:@"_library_600x900.jpg"]] ])
    if ([NSFileManager.defaultManager fileExistsAtPath:path]) return path;
  return nil;
}

/* Draws `image` into `size` points, filled or fitted, with rounded corners. */
static UIImage *Render(UIImage *image, CGSize size, CGFloat scale, BOOL fill, CGFloat radius) {
  UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
  format.scale = scale;
  UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
  return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx __unused) {
    CGRect box = { CGPointZero, size };
    [[UIBezierPath bezierPathWithRoundedRect:box cornerRadius:radius] addClip];
    CGFloat sx = size.width / image.size.width, sy = size.height / image.size.height;
    CGFloat s = fill ? MAX(sx, sy) : MIN(sx, sy);
    CGSize drawn = { image.size.width * s, image.size.height * s };
    [image drawInRect:CGRectMake((size.width - drawn.width) / 2, (size.height - drawn.height) / 2, drawn.width, drawn.height)];
  }];
}

@implementation WineIcons {
  NSCache<NSString *, id> *_memory;
  NSMutableDictionary<NSString *, NSMutableArray *> *_waiting;
  dispatch_queue_t _queue;
  NSString *_dir;
  CGFloat _scale;
}

/* First used from the main thread, which init needs for the screen scale. */
+ (instancetype)shared {
  static WineIcons *s;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ s = [WineIcons new]; });
  return s;
}

- (instancetype)init {
  if ((self = [super init])) {
    _memory = [NSCache new];
    _waiting = [NSMutableDictionary dictionary];
    _queue = dispatch_queue_create("dev.kitsune.icons", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    _dir = [caches stringByAppendingPathComponent:@"icons"];
    _scale = UIScreen.mainScreen.scale;
    [NSFileManager.defaultManager createDirectoryAtPath:_dir withIntermediateDirectories:YES attributes:nil error:nil];
  }
  return self;
}

/* A cache key that changes when the source file does. */
static NSString *KeyFor(NSString *kind, NSString *path) {
  NSDictionary *a = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
  NSString *identity = [NSString stringWithFormat:@"%@|%@|%llu|%f", kind, path, a.fileSize, a.fileModificationDate.timeIntervalSince1970];
  const char *s = identity.UTF8String;
  unsigned char digest[CC_SHA1_DIGEST_LENGTH];
  CC_SHA1(s, (CC_LONG)strlen(s), digest);
  NSMutableString *hex = [NSMutableString string];
  for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
  return hex;
}

- (UIImage *)lookup:(NSString *)source kind:(NSString *)kind ready:(void (^)(void))ready
               make:(UIImage *(^)(void))make {
  if (!source) return nil;
  NSString *memoryKey = [kind stringByAppendingString:source];
  id cached = [_memory objectForKey:memoryKey];
  if (cached) return cached == NSNull.null ? nil : cached;
  NSMutableArray *waiters = _waiting[memoryKey];
  if (waiters) {
    if (ready) [waiters addObject:ready];
    return nil;
  }
  _waiting[memoryKey] = ready ? [NSMutableArray arrayWithObject:ready] : [NSMutableArray array];
  dispatch_async(_queue, ^{
    NSString *file = [self->_dir stringByAppendingPathComponent:[KeyFor(kind, source) stringByAppendingString:@".png"]];
    NSData *png = [NSData dataWithContentsOfFile:file];
    UIImage *image = png.length ? [UIImage imageWithData:png scale:self->_scale] : nil;
    if (!png) {
      image = make();
      NSData *out = image ? UIImagePNGRepresentation(image) : [NSData data];
      [out writeToFile:file atomically:YES];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      [self->_memory setObject:image ?: (id)NSNull.null forKey:memoryKey];
      NSArray *done = self->_waiting[memoryKey];
      [self->_waiting removeObjectForKey:memoryKey];
      for (void (^block)(void) in done) block();
    });
  });
  return nil;
}

- (UIImage *)iconForExecutable:(NSString *)path ready:(void (^)(void))ready {
  return [self lookup:path kind:@"exe" ready:ready make:^UIImage * {
    unsigned char *bytes = NULL;
    size_t len = 0;
    if (pe_icon_extract(path.fileSystemRepresentation, &bytes, &len)) return nil;
    UIImage *raw = [UIImage imageWithData:[NSData dataWithBytesNoCopy:bytes length:len freeWhenDone:YES]];
    return raw ? Render(raw, WineProgramIconSize, self->_scale, NO, 8) : nil;
  }];
}

- (UIImage *)artForSteamApp:(NSString *)appID steamRoot:(NSString *)root ready:(void (^)(void))ready {
  NSString *path = root && appID ? KitsuneSteamArtPath(root, appID) : nil;
  return [self lookup:path kind:@"steam" ready:ready make:^UIImage * {
    UIImage *raw = [UIImage imageWithContentsOfFile:path];
    return raw ? Render(raw, WineSteamArtSize, self->_scale, YES, 5) : nil;
  }];
}

@end

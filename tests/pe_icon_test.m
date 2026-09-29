#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include <assert.h>
#include <stdio.h>
#include "../src/ios/pe_icon.c"

static void put16(NSMutableData *d, NSUInteger off, uint16_t v) { wr16((unsigned char *)d.mutableBytes + off, v); }
static void put32(NSMutableData *d, NSUInteger off, uint32_t v) { wr32((unsigned char *)d.mutableBytes + off, v); }

/* A 32-bit DIB icon image: header, BGRA rows, AND mask. */
static NSData *DibIcon(int px) {
  NSUInteger mask_row = ((NSUInteger)(px + 31) / 32) * 4;
  NSMutableData *d = [NSMutableData dataWithLength:40 + (NSUInteger)(px * px * 4) + mask_row * (NSUInteger)px];
  put32(d, 0, 40); put32(d, 4, (uint32_t)px); put32(d, 8, (uint32_t)px * 2);
  put16(d, 12, 1); put16(d, 14, 32);
  memset((unsigned char *)d.mutableBytes + 40, 0x80, (size_t)(px * px * 4));
  return d;
}

static NSData *PngIcon(int px) {
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(NULL, (size_t)px, (size_t)px, 8, 0, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
  CGContextSetRGBFillColor(ctx, 0.2, 0.4, 0.8, 1);
  CGContextFillRect(ctx, CGRectMake(0, 0, px, px));
  CGImageRef img = CGBitmapContextCreateImage(ctx);
  NSMutableData *out = [NSMutableData data];
  CGImageDestinationRef dst = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out, CFSTR("public.png"), 1, NULL);
  CGImageDestinationAddImage(dst, img, NULL);
  assert(CGImageDestinationFinalize(dst));
  CFRelease(dst); CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(cs);
  return out;
}

/* A PE32+ image whose only section is .rsrc: one icon group over the images,
 * which get ids 1..n. */
static NSData *MakePE(NSArray<NSData *> *images, NSArray<NSNumber *> *sizes) {
  const uint32_t rva = 0x1000;
  NSUInteger n = images.count;
  NSMutableData *res = [NSMutableData data];
  NSUInteger (^alloc)(NSUInteger) = ^NSUInteger(NSUInteger len) {
    NSUInteger off = res.length;
    [res increaseLengthBy:(len + 3) & ~(NSUInteger)3];
    return off;
  };
  void (^dir)(NSUInteger, uint16_t) = ^(NSUInteger off, uint16_t ids) { put16(res, off + 14, ids); };
  void (^entry)(NSUInteger, uint32_t, uint32_t) = ^(NSUInteger off, uint32_t name, uint32_t target) {
    put32(res, off, name); put32(res, off + 4, target);
  };
  NSUInteger root = alloc(16 + 2 * 8), iconDir = alloc(16 + n * 8), groupDir = alloc(16 + 8), groupLang = alloc(16 + 8);
  NSUInteger iconLang[8], iconEntry[8], iconData[8];
  for (NSUInteger i = 0; i < n; i++) iconLang[i] = alloc(16 + 8);
  for (NSUInteger i = 0; i < n; i++) iconEntry[i] = alloc(16);
  NSUInteger groupEntry = alloc(16);
  for (NSUInteger i = 0; i < n; i++) iconData[i] = alloc(images[i].length);
  NSUInteger groupData = alloc(6 + n * 14);

  dir(root, 2);
  entry(root + 16, RT_ICON, DIR_BIT | (uint32_t)iconDir);
  entry(root + 24, RT_GROUP_ICON, DIR_BIT | (uint32_t)groupDir);
  dir(iconDir, (uint16_t)n);
  dir(groupDir, 1);
  entry(groupDir + 16, 1, DIR_BIT | (uint32_t)groupLang);
  dir(groupLang, 1);
  entry(groupLang + 16, 0x409, (uint32_t)groupEntry);
  put32(res, groupEntry, rva + (uint32_t)groupData);
  put32(res, groupEntry + 4, (uint32_t)(6 + n * 14));
  put16(res, groupData + 2, 1);
  put16(res, groupData + 4, (uint16_t)n);
  for (NSUInteger i = 0; i < n; i++) {
    entry(iconDir + 16 + i * 8, (uint32_t)i + 1, DIR_BIT | (uint32_t)iconLang[i]);
    dir(iconLang[i], 1);
    entry(iconLang[i] + 16, 0x409, (uint32_t)iconEntry[i]);
    put32(res, iconEntry[i], rva + (uint32_t)iconData[i]);
    put32(res, iconEntry[i] + 4, (uint32_t)images[i].length);
    [res replaceBytesInRange:NSMakeRange(iconData[i], images[i].length) withBytes:images[i].bytes];
    NSUInteger g = groupData + 6 + i * 14;
    int px = sizes[i].intValue;
    ((unsigned char *)res.mutableBytes)[g] = (unsigned char)(px >= 256 ? 0 : px);
    ((unsigned char *)res.mutableBytes)[g + 1] = (unsigned char)(px >= 256 ? 0 : px);
    put16(res, g + 4, 1);
    put16(res, g + 6, 32);
    put32(res, g + 8, (uint32_t)images[i].length);
    put16(res, g + 12, (uint16_t)(i + 1));
  }

  NSMutableData *pe = [NSMutableData dataWithLength:0x200];
  memcpy(pe.mutableBytes, "MZ", 2);
  put32(pe, 0x3c, 0x40);
  memcpy((unsigned char *)pe.mutableBytes + 0x40, "PE\0\0", 4);
  put16(pe, 0x44, 0x8664);
  put16(pe, 0x46, 1);
  put16(pe, 0x54, 240);
  put16(pe, 0x56, 0x22);
  put16(pe, 0x58, 0x20b);
  put32(pe, 0x58 + 108, 16);
  put32(pe, 0x58 + 112 + 16, rva);
  put32(pe, 0x58 + 112 + 20, (uint32_t)res.length);
  memcpy((unsigned char *)pe.mutableBytes + 0x148, ".rsrc", 5);
  put32(pe, 0x148 + 8, (uint32_t)res.length);
  put32(pe, 0x148 + 12, rva);
  put32(pe, 0x148 + 16, (uint32_t)res.length);
  put32(pe, 0x148 + 20, 0x200);
  [pe appendData:res];
  return pe;
}

static NSString *Write(NSData *d) {
  NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
  [d writeToFile:path atomically:NO];
  return path;
}

/* Extracts and decodes; returns the decoded width, or 0 when there is no icon. */
static size_t IconWidth(NSData *pe, BOOL *png) {
  NSString *path = Write(pe);
  unsigned char *buf = NULL;
  size_t len = 0;
  int rc = pe_icon_extract(path.fileSystemRepresentation, &buf, &len);
  [NSFileManager.defaultManager removeItemAtPath:path error:nil];
  if (rc) return 0;
  if (png) *png = len >= 8 && !memcmp(buf, "\x89PNG", 4);
  NSData *d = [NSData dataWithBytesNoCopy:buf length:len freeWhenDone:YES];
  CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)d, NULL);
  assert(src);
  CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
  assert(img);
  size_t w = CGImageGetWidth(img);
  CGImageRelease(img);
  CFRelease(src);
  return w;
}

int main(void) {
  @autoreleasepool {
    BOOL png = NO;
    NSData *both = MakePE(@[ DibIcon(16), PngIcon(256) ], @[ @16, @256 ]);
    assert(IconWidth(both, &png) == 256 && png);
    NSData *dib = MakePE(@[ DibIcon(16), DibIcon(32) ], @[ @16, @32 ]);
    assert(IconWidth(dib, &png) == 32 && !png);

    for (NSUInteger cut = 0; cut < both.length; cut += 5)
      (void)IconWidth([both subdataWithRange:NSMakeRange(0, cut)], NULL);
    srandom(7);
    for (int round = 0; round < 3000; round++) {
      NSMutableData *bad = [both mutableCopy];
      for (int k = 0; k < 4; k++) ((unsigned char *)bad.mutableBytes)[random() % bad.length] = (unsigned char)random();
      NSString *path = Write(bad);
      unsigned char *buf = NULL;
      size_t len = 0;
      if (!pe_icon_extract(path.fileSystemRepresentation, &buf, &len)) free(buf);
      [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    }
    assert(IconWidth([@"not a program" dataUsingEncoding:NSUTF8StringEncoding], NULL) == 0);

    NSString *winemine = [[@(__FILE__).stringByDeletingLastPathComponent stringByDeletingLastPathComponent]
                          stringByAppendingPathComponent:@"out/wine-core/lib/wine/aarch64-windows/winemine.exe"];
    NSData *real = [NSData dataWithContentsOfFile:winemine];
    if (real) assert(IconWidth(real, NULL) >= 16);
    printf("PE ICON PASS: largest image chosen, PNG kept, DIB wrapped as ICO, truncated and corrupted images refused%s\n",
           real ? ", winemine.exe decodes" : "");
  }
}

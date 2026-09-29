#import "../src/ios/game_config.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
  @autoreleasepool {
    NSMutableString *a = [NSMutableString stringWithString:
        @"<?xml version=\"1.0\"?>\n<GraphicsConfig>\n <Resolution-Width>800</Resolution-Width>\n"
         " <Resolution-Height> 600 </Resolution-Height>\n <Fullscreen>true</Fullscreen>\n</GraphicsConfig>\n"];
    assert(IOSWineRewriteGraphicsConfigXML(a, 1275, 627));
    assert([a containsString:@"<Resolution-Width>1275</Resolution-Width>"]);
    assert([a containsString:@"<Resolution-Height>627</Resolution-Height>"]);
    assert([a containsString:@"<Fullscreen>true</Fullscreen>"]);

    NSMutableString *b = [NSMutableString stringWithString:
        @"<Config><Resolution>\n  <Width>800</Width>\n  <Height>600</Height>\n</Resolution><Other><Width>5</Width></Other></Config>"];
    assert(IOSWineRewriteGraphicsConfigXML(b, 1350, 624));
    assert([b containsString:@"<Width>1350</Width>\n  <Height>624</Height>"]);
    assert([b containsString:@"<Other><Width>5</Width></Other>"]);   /* unrelated Width untouched */

    NSMutableString *c = [NSMutableString stringWithString:@"<Config><Fullscreen>true</Fullscreen></Config>"];
    assert(!IOSWineRewriteGraphicsConfigXML(c, 1000, 800));
    assert([c isEqualToString:@"<Config><Fullscreen>true</Fullscreen></Config>"]);

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *bottle = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"game-config-test-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *dir = [bottle stringByAppendingPathComponent:@"drive_c/users/wine/Documents/NBGI/DARK SOULS REMASTERED"];
    assert([fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil]);
    assert(!IOSWineApplyGameResolution(@"570940", bottle, 1275, 627));   /* no config yet */
    NSString *file = [dir stringByAppendingPathComponent:@"GraphicsConfig.xml"];
    assert([@"<GraphicsConfig><Resolution-Width>800</Resolution-Width><Resolution-Height>600</Resolution-Height></GraphicsConfig>"
        writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    assert([IOSWineApplyGameResolution(@"570940", bottle, 1275, 627) isEqualToString:file]);
    NSString *out = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil];
    assert([out containsString:@"<Resolution-Width>1275</Resolution-Width><Resolution-Height>627</Resolution-Height>"]);
    assert(!IOSWineApplyGameResolution(@"570940", bottle, 100, 100));    /* absurd sizes refused */
    assert(!IOSWineApplyGameResolution(@"70", bottle, 1275, 627));       /* unknown title */
    assert([fm removeItemAtPath:bottle error:nil]);
    puts("GAME CONFIG PASS: both XML forms, unrelated tags untouched, missing config and unknown titles refused");
  }
}

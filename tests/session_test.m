#import "../src/ios/session.m"
#include <assert.h>
#include <stdio.h>

static int fake_processes;
int wineserver_inproc_user_processes(void) { return fake_processes; }

int main(void) {
  @autoreleasepool {
    char cmdline[4096], cwd[1024];

    /* First in, first out, with phone paths as Windows paths. */
    assert(wine_surface_host_take_launch(cmdline, sizeof(cmdline), cwd, sizeof(cwd)) == 0);
    assert(IOSWineSessionQueue(@[ @"/Apps/Steam/steam.exe", @"-applaunch", @"440" ], @"/Apps/Steam"));
    assert(IOSWineSessionQueue(@[ @"/Apps/My Game/game.exe" ], nil));
    assert(wine_surface_host_take_launch(cmdline, sizeof(cmdline), cwd, sizeof(cwd)) == 1);
    assert(!strcmp(cmdline, "Z:\\Apps\\Steam\\steam.exe -applaunch 440") && !strcmp(cwd, "Z:\\Apps\\Steam"));
    assert(wine_surface_host_take_launch(cmdline, sizeof(cmdline), cwd, sizeof(cwd)) == 1);
    assert(!strcmp(cmdline, "\"Z:\\Apps\\My Game\\game.exe\"") && !cwd[0]);
    assert(wine_surface_host_take_launch(cmdline, sizeof(cmdline), cwd, sizeof(cwd)) == 0);

    /* What the driver cannot pass on is refused up front, or reported. */
    NSString *huge = [@"" stringByPaddingToLength:5000 withString:@"x" startingAtIndex:0];
    assert(!IOSWineSessionQueue(@[ @"/a.exe", huge ], nil));
    assert(!IOSWineSessionQueue(@[], nil));
    assert(IOSWineSessionQueue(@[ @"/a.exe", @"12345678" ], nil));
    char small[8];
    assert(wine_surface_host_take_launch(small, sizeof(small), cwd, sizeof(cwd)) == -1);
    for (int i = 0; i < 16; i++) assert(IOSWineSessionQueue(@[ @"/a.exe" ], nil));
    assert(!IOSWineSessionQueue(@[ @"/a.exe" ], nil));
    while (wine_surface_host_take_launch(cmdline, sizeof(cmdline), cwd, sizeof(cwd)) == 1) {}

    /* The host is a process too; it is not a program. */
    fake_processes = 0;
    assert(IOSWineSessionPrograms() == 0);
    fake_processes = 1;
    assert(IOSWineSessionPrograms() == 0);
    fake_processes = 3;
    assert(IOSWineSessionPrograms() == 2);
    assert([IOSWineSessionHostPath() hasSuffix:@"lib/wine/aarch64-windows/ioswine-session.exe"]);
    puts("SESSION PASS: launches queue in order as Windows command lines, oversize ones are refused, the host is not counted");
  }
}

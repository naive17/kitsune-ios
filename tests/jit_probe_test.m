#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdio.h>
#include "../src/jit/jit_alloc.c"

/* Without a debugger the handshake's breakpoint raises SIGTRAP. The app polls
 * it while waiting for StikDebug to attach with the script, so a failure must
 * be survivable any number of times and never remembered. */
int main(void) {
  @autoreleasepool {
    char err[256];
    for (int i = 0; i < 2000; i++) {
      err[0] = 0;
      assert(!jit_alloc_available(err, sizeof err));
      assert(strstr(err, "no debugger"));
    }
    jit_region region;
    assert(!jit_region_alloc(1 << 20, &region, err, sizeof err) && !region.exec);
    assert(!jit_detach(err, sizeof err) && strstr(err, "detach brk raised"));
    assert(!jit_alloc_available(err, sizeof err));
    puts("JIT PROBE PASS: a missing debugger raises a caught SIGTRAP, repeatedly, and is never cached");
  }
}

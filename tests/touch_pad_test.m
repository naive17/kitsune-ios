#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdio.h>
#include "../src/ios/gamepad_state.h"
#include "../src/ios/touch_gamepad_layout.h"

/* Shared edges and corners, like the d-pad arms', do not count. */
static int overlaps(IOSWinePadRect a, IOSWinePadRect b) {
  const double e = 1e-6;
  return a.x < b.x + b.w - e && b.x < a.x + a.w - e && a.y < b.y + b.h - e && b.y < a.y + a.h - e;
}

static void check_layout(double w, double h, double l, double t, double r, double b) {
  IOSWinePadScreen s = { w, h, l, t, r, b };
  IOSWinePadRect rc[TP_COUNT];
  double u = IOSWinePadLayout(s, rc);
  IOSWinePadRect bar = IOSWinePadReservedTop(s);
  assert(u >= 40 && u <= 56);
  assert(bar.x >= l && bar.x + bar.w <= w - r);
  for (int i = 0; i < TP_COUNT; i++) {
    assert(rc[i].w > 0 && rc[i].h > 0);
    assert(rc[i].x >= l && rc[i].y >= t && rc[i].x + rc[i].w <= w - r && rc[i].y + rc[i].h <= h - b);
    assert(!overlaps(rc[i], bar));
    for (int j = i + 1; j < TP_COUNT; j++) assert(!overlaps(rc[i], rc[j]));
  }
}

int main(void) {
  @autoreleasepool {
    struct ios_touch_pad touch = { .active = 1, .buttons = 0x1000, .left_trigger = 200, .lx = 20000, .ly = -20000, .rx = 3000 };
    struct ios_gamepad_state none = {0};
    IOSWineGamepadMergeTouch(&none, &touch);
    assert(none.connected && none.battery_type == 1 && none.buttons == 0x1000);
    assert(none.left_trigger == 200 && none.lx == 20000 && none.ly == -20000 && none.rx == 3000);

    struct ios_gamepad_state pad = { .connected = 1, .buttons = 0x2000, .left_trigger = 250, .right_trigger = 10, .lx = 30000, .ly = 0, .rx = 100, .ry = -100 };
    IOSWineGamepadMergeTouch(&pad, &touch);
    assert(pad.buttons == 0x3000);
    assert(pad.left_trigger == 250 && pad.right_trigger == 10);
    assert(pad.lx == 30000 && pad.ly == 0);          /* physical stick outside the dead zone wins */
    assert(pad.rx == 3000 && pad.ry == 0);           /* physical stick inside the dead zone yields */

    struct ios_touch_pad off = { .active = 0, .buttons = 0xffff };
    struct ios_gamepad_state quiet = {0};
    IOSWineGamepadMergeTouch(&quiet, &off);
    assert(!quiet.connected && !quiet.buttons);

    check_layout(844, 390, 47, 0, 47, 21);   /* iPhone 14 */
    check_layout(932, 430, 59, 0, 59, 21);   /* Pro Max */
    check_layout(852, 393, 59, 0, 59, 21);   /* 15 / 16 */
    check_layout(667, 375, 0, 0, 0, 0);      /* SE */
    check_layout(390, 844, 0, 47, 0, 34);    /* portrait */
    check_layout(430, 932, 0, 59, 0, 34);
    check_layout(375, 667, 0, 20, 0, 0);
    assert(IOSWineBarRows(844 - 94) == 1 && IOSWineBarRows(667) == 1);
    assert(IOSWineBarRows(390) == 2 && IOSWineBarRows(375) == 2);
    assert(IOSWineBarWidth(IOSWINE_BAR_BUTTONS) <= 844 - 94 - 16);
    for (int i = 0; i < TP_COUNT; i++) assert(kIOSWinePadLabel[i]);
    assert(kIOSWinePadButton[TP_A] == 0x1000 && kIOSWinePadButton[TP_MENU] == 0x0010 && !kIOSWinePadButton[TP_LT]);
    puts("TOUCH PAD PASS: merge rules, dead zones, inactive pad ignored, layout fits the safe area without overlaps on seven screens in both orientations, bar rows");
  }
}

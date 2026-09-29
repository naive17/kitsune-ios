#include <assert.h>
#include <stdio.h>
#include "../src/ios/gamepad_state.h"
#include "../src/ios/key_pulse.h"

static int events[1024][2], count;
static void sink(int vk, int scan, int down) {
    assert(!scan && count < 1024);
    events[count][0] = vk;
    events[count++][1] = down;
}
/* Characters are recorded as negative codes, keys as virtual keys. */
static void text(int codepoint, int down) {
    assert(count < 1024);
    events[count][0] = -codepoint;
    events[count++][1] = down;
}

int main(void) {
    assert(IOSWineGamepadAxis(-1) == -32768);
    assert(IOSWineGamepadAxis(1) == 32767);
    assert(IOSWineGamepadAxis(-4) == -32768);
    assert(IOSWineGamepadAxis(4) == 32767);
    assert(IOSWineGamepadAxis(0) == 0);
    assert(IOSWineGamepadAxis(-0.5f) == -16384);
    assert(IOSWineGamepadAxis(0.5f) == 16384);
    assert(IOSWineGamepadAxis(NAN) == 0 && IOSWineGamepadAxis(INFINITY) == 0);
    assert(IOSWineGamepadTrigger(0.5f) == 128);
    assert(IOSWineGamepadTrigger(-1) == 0 && IOSWineGamepadTrigger(2) == 255);
    assert(IOSWineGamepadTrigger(NAN) == 0);

    struct ios_gamepad_state pad = {0}, next = {.connected = 1, .battery_type = 1};
    IOSWineGamepadPublish(&pad, next);
    assert(pad.packet == 1 && pad.connected);
    IOSWineGamepadPublish(&pad, next);
    assert(pad.packet == 1);
    next.buttons = 0xf7ff;
    next.lx = -32768; next.ry = 32767; next.right_trigger = 255;
    IOSWineGamepadPublish(&pad, next);
    assert(pad.packet == 2 && pad.buttons == 0xf7ff && pad.right_trigger == 255);
    next.battery_level = 3;
    IOSWineGamepadPublish(&pad, next);
    assert(pad.packet == 2 && pad.battery_level == 3);
    next.connected = 0;
    IOSWineGamepadPublish(&pad, next);
    assert(pad.packet == 3 && !pad.buttons && !pad.lx && !pad.ry && !pad.right_trigger);
    IOSWineGamepadPublish(&pad, next);
    assert(pad.packet == 3);
    next = (struct ios_gamepad_state){.connected = 1};
    IOSWineGamepadPublish(&pad, next);
    assert(pad.packet == 4);
    pad.packet = UINT32_MAX; next.buttons = 1;
    IOSWineGamepadPublish(&pad, next);
    assert(pad.packet == 1);

    struct ios_key_pulse p = IOSWineGameTextPulse('e');
    assert(p.vk == 69 && p.mods == 0);
    p = IOSWineGameTextPulse('E');
    assert(p.vk == 69 && p.mods == 4);          // a capital keeps its Shift
    p = IOSWineGameTextPulse('9');
    assert(p.vk == '9' && p.mods == 0);
    p = IOSWineGameTextPulse(0x00e9);
    assert(p.vk == 0x00e9 && p.mods == 8);      // stays a character
    p = IOSWineGameTextPulse('!');
    assert(p.vk == '!' && p.mods == 8);
    struct ios_key_pulses q = {0};
    assert(IOSWinePulsePush(&q, 69, 0));
    assert(IOSWinePulsePush(&q, 69, 0));
    IOSWinePulseTick(&q, 1000, sink, text);
    assert(count == 1 && events[0][0] == 69 && events[0][1] == 1);
    IOSWinePulseTick(&q, 1079, sink, text); assert(count == 1);
    IOSWinePulseTick(&q, 1080, sink, text); assert(count == 2 && !events[1][1]);
    IOSWinePulseTick(&q, 1129, sink, text); assert(count == 2);
    IOSWinePulseTick(&q, 1130, sink, text); assert(count == 3 && events[2][1]);
    IOSWinePulseTick(&q, 1210, sink, text); assert(count == 4 && !events[3][1]);
    IOSWinePulseTick(&q, 1260, sink, text); assert(!q.phase && q.head == q.tail);
    assert(IOSWinePulsePush(&q, 67, 7));
    IOSWinePulseTick(&q, 1300, sink, text);
    assert(count == 8 && events[4][0] == 0x11 && events[7][0] == 67);
    IOSWinePulseCancel(&q, sink, text);
    assert(count == 12 && events[8][0] == 67 && !events[8][1] && !events[11][1]);
    assert(!q.phase && q.head == q.tail);
    for (int i = 0; i < 63; ++i) assert(IOSWinePulsePush(&q, 65, 0));
    assert(!IOSWinePulsePush(&q, 66, 0));
    IOSWinePulseTick(&q, 2000, sink, text);
    IOSWinePulseTick(&q, 9000, sink, text); // Delayed scheduler still emits only release.
    assert(q.phase == 2 && q.deadline == 9050);
    IOSWinePulseCancel(&q, sink, text);

    // "aB!" arrives in order: a, Shift+B, then the character.
    count = 0;
    const char *typed = "aB!";
    for (const char *c = typed; *c; c++) {
        p = IOSWineGameTextPulse((uint16_t)*c);
        assert(IOSWinePulsePush(&q, p.vk, p.mods));
    }
    for (uint64_t t = 3000; q.phase || q.head != q.tail; t += 10) IOSWinePulseTick(&q, t, sink, text);
    int want[][2] = {{'A',1},{'A',0},{0x10,1},{'B',1},{'B',0},{0x10,0},{-'!',1},{-'!',0}};
    assert(count == 8);
    for (int i = 0; i < 8; i++) assert(events[i][0] == want[i][0] && events[i][1] == want[i][1]);
    puts("GAMEPAD/KEY PASS: analog ranges, packet/hotplug state, Unicode policy, capitals with Shift, text in order, 80ms press/50ms release, modifiers/cancel/FIFO");
}

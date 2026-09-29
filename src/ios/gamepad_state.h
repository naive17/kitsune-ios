/* Pure state conversion/publishing, shared by production and native tests. */
#ifndef IOSWINE_GAMEPAD_STATE_H
#define IOSWINE_GAMEPAD_STATE_H
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "../../third_party/wine/include/wine/ios_gamepad.h"

static inline int16_t IOSWineGamepadAxis(float value)
{
    if (!isfinite(value)) return 0;
    if (value <= -1) return -32768;
    if (value >= 1) return 32767;
    return (int16_t)lroundf(value * (value < 0 ? 32768.0f : 32767.0f));
}

static inline uint8_t IOSWineGamepadTrigger(float value)
{
    if (!isfinite(value) || value <= 0) return 0;
    if (value >= 1) return 255;
    return (uint8_t)lroundf(value * 255.0f);
}

/* The on-screen pad, merged into slot 0. */
struct ios_touch_pad
{
    int active;
    uint16_t buttons;
    uint8_t left_trigger, right_trigger;
    int16_t lx, ly, rx, ry;
};

#define IOSWINE_XINPUT_LEFT_DEADZONE  7849
#define IOSWINE_XINPUT_RIGHT_DEADZONE 8689

/* Touch input joins a physical pad in slot 0: buttons are OR'd, triggers take
 * the larger value, and a physical stick outside the XInput dead zone wins. */
static inline void IOSWineGamepadMergeTouch(struct ios_gamepad_state *next, const struct ios_touch_pad *touch)
{
    if (!touch->active) return;
    if (!next->connected)
    {
        next->connected = 1;
        next->battery_type = 1;
    }
    next->buttons |= touch->buttons;
    if (touch->left_trigger > next->left_trigger) next->left_trigger = touch->left_trigger;
    if (touch->right_trigger > next->right_trigger) next->right_trigger = touch->right_trigger;
    if (abs(next->lx) < IOSWINE_XINPUT_LEFT_DEADZONE && abs(next->ly) < IOSWINE_XINPUT_LEFT_DEADZONE)
    {
        next->lx = touch->lx;
        next->ly = touch->ly;
    }
    if (abs(next->rx) < IOSWINE_XINPUT_RIGHT_DEADZONE && abs(next->ry) < IOSWINE_XINPUT_RIGHT_DEADZONE)
    {
        next->rx = touch->rx;
        next->ry = touch->ry;
    }
}

/* Caller serializes access. Packet changes only on connection/input changes,
 * not polls, duplicate callbacks or battery-only changes. Disconnect clears
 * held input; reconnect keeps a monotonically advancing packet sequence. */
static inline void IOSWineGamepadPublish(struct ios_gamepad_state *dst,
                                         struct ios_gamepad_state next)
{
    uint32_t packet = dst->packet;
    next.packet = packet;
    next.reserved = 0;
    if (!next.connected) {
        memset(&next, 0, sizeof(next));
        next.packet = packet;
    }
    if (dst->connected != next.connected ||
        memcmp(&dst->buttons, &next.buttons, 12)) {
        if (!++packet) ++packet;
    }
    next.packet = packet;
    *dst = next;
}
#endif

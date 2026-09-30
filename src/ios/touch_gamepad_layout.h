/* Placement of the on-screen gamepad's controls and of the session bar that
 * shares the screen with it. Points throughout. */
#ifndef KITSUNE_TOUCH_GAMEPAD_LAYOUT_H
#define KITSUNE_TOUCH_GAMEPAD_LAYOUT_H

#include <math.h>
#include <stdint.h>

typedef struct { double x, y, w, h; } KitsunePadRect;
typedef struct { double width, height, left, top, right, bottom; } KitsunePadScreen;   /* size and safe-area insets */

enum {
    TP_LSTICK, TP_RSTICK,
    TP_A, TP_B, TP_X, TP_Y,
    TP_UP, TP_DOWN, TP_LEFT, TP_RIGHT,
    TP_LB, TP_LT, TP_RB, TP_RT,
    TP_VIEW, TP_MENU,
    TP_COUNT
};

/* XInput button bits; sticks and triggers carry 0. */
static const uint16_t kKitsunePadButton[TP_COUNT] = {
    [TP_A] = 0x1000, [TP_B] = 0x2000, [TP_X] = 0x4000, [TP_Y] = 0x8000,
    [TP_UP] = 0x0001, [TP_DOWN] = 0x0002, [TP_LEFT] = 0x0004, [TP_RIGHT] = 0x0008,
    [TP_LB] = 0x0100, [TP_RB] = 0x0200, [TP_VIEW] = 0x0020, [TP_MENU] = 0x0010,
};

static const char *const kKitsunePadLabel[TP_COUNT] = {
    "", "", "A", "B", "X", "Y", "▲", "▼", "◀", "▶", "LB", "LT", "RB", "RT", "View", "Menu",
};

/* The session bar: buttons of 38 pt with 2 pt gaps and 8 pt margins. */
#define KITSUNE_BAR_BUTTONS 12
#define KITSUNE_BAR_BUTTON_WIDTH 38.0
static inline double KitsuneBarWidth(int buttons)
{
    return buttons * KITSUNE_BAR_BUTTON_WIDTH + (buttons - 1) * 2 + 16;
}

static inline int KitsuneBarRows(double safeWidth)
{
    return safeWidth >= KitsuneBarWidth(KITSUNE_BAR_BUTTONS) + 16 ? 1 : 2;
}

/* Kept clear for the session bar and the performance overlay under it, which
 * move to the top centre while the pad is shown. */
static inline KitsunePadRect KitsunePadReservedTop(KitsunePadScreen s)
{
    double safeWidth = s.width - s.left - s.right, cx = s.left + safeWidth / 2;
    int rows = KitsuneBarRows(safeWidth);
    double w = KitsuneBarWidth(rows == 1 ? KITSUNE_BAR_BUTTONS : (KITSUNE_BAR_BUTTONS + 1) / 2) + 10;
    KitsunePadRect r = { cx - w / 2, s.top, w, rows == 1 ? 80 : 110 };
    return r;
}

/* Fills out[] and returns the unit size. Landscape: left stick bottom left
 * with the d-pad above it, face buttons bottom right with the right stick
 * inboard, shoulders in the top corners; the left column needs about 6.3
 * units of height, so a unit is at most 15% of it. Portrait: the right stick
 * sits above the face buttons and each pair of shoulders above its column,
 * View and Menu at the bottom centre. */
static inline double KitsunePadLayout(KitsunePadScreen s, KitsunePadRect out[TP_COUNT])
{
    double left = s.left, right = s.width - s.right, top = s.top, bottom = s.height - s.bottom;
    int portrait = s.width < s.height;
    double u = portrait ? fmin(fmax((right - left) * 0.13, 40), 52) : fmin(fmax((bottom - top) * 0.15, 42), 56);
    double stick = 2.2 * u, face = 0.9 * u, dpad = 0.72 * u, shw = 1.1 * u, shh = 0.62 * u, off = 0.95 * u;
    double margin = portrait ? 0.3 * u : 0.25 * u;
    double lsx = left + (portrait ? 0.3 : 0.35) * u, lsy = bottom - stick - margin;
    double fcx = right - 1.55 * u, fcy = bottom - 1.45 * u;
    double dcx = lsx + stick / 2, dcy = lsy - 1.25 * u;
    double faceTop = fcy - off - face / 2;

    out[TP_LSTICK] = (KitsunePadRect){ lsx, lsy, stick, stick };
    out[TP_A] = (KitsunePadRect){ fcx - face / 2, fcy + off - face / 2, face, face };
    out[TP_B] = (KitsunePadRect){ fcx + off - face / 2, fcy - face / 2, face, face };
    out[TP_X] = (KitsunePadRect){ fcx - off - face / 2, fcy - face / 2, face, face };
    out[TP_Y] = (KitsunePadRect){ fcx - face / 2, faceTop, face, face };
    out[TP_UP] = (KitsunePadRect){ dcx - dpad / 2, dcy - dpad * 1.5, dpad, dpad };
    out[TP_DOWN] = (KitsunePadRect){ dcx - dpad / 2, dcy + dpad * 0.5, dpad, dpad };
    out[TP_LEFT] = (KitsunePadRect){ dcx - dpad * 1.5, dcy - dpad / 2, dpad, dpad };
    out[TP_RIGHT] = (KitsunePadRect){ dcx + dpad * 0.5, dcy - dpad / 2, dpad, dpad };

    if (portrait)
    {
        double cx = (left + right) / 2;
        double rsy = faceTop - 0.35 * u - stick;
        double lb = dcy - dpad * 1.5 - 0.3 * u - shh, rb = rsy - 0.3 * u - shh;
        out[TP_RSTICK] = (KitsunePadRect){ fcx - stick / 2, rsy, stick, stick };
        out[TP_LB] = (KitsunePadRect){ left + 0.2 * u, lb, shw, shh };
        out[TP_LT] = (KitsunePadRect){ left + 0.2 * u, lb - 0.12 * u - shh, shw, shh };
        out[TP_RB] = (KitsunePadRect){ right - 0.2 * u - shw, rb, shw, shh };
        out[TP_RT] = (KitsunePadRect){ right - 0.2 * u - shw, rb - 0.12 * u - shh, shw, shh };
        out[TP_VIEW] = (KitsunePadRect){ cx - 0.15 * u - shw, bottom - shh - margin, shw, shh };
        out[TP_MENU] = (KitsunePadRect){ cx + 0.15 * u, bottom - shh - margin, shw, shh };
    }
    else
    {
        out[TP_RSTICK] = (KitsunePadRect){ fcx - off - face / 2 - 0.35 * u - stick, lsy, stick, stick };
        out[TP_LT] = (KitsunePadRect){ left + 0.2 * u, top + 0.12 * u, shw, shh };
        out[TP_LB] = (KitsunePadRect){ left + 0.2 * u, top + 0.24 * u + shh, shw, shh };
        out[TP_RT] = (KitsunePadRect){ right - 0.2 * u - shw, top + 0.12 * u, shw, shh };
        out[TP_RB] = (KitsunePadRect){ right - 0.2 * u - shw, top + 0.24 * u + shh, shw, shh };
        out[TP_VIEW] = (KitsunePadRect){ dcx + dpad * 1.5 + 0.4 * u, dcy - shh / 2, shw, shh };
        out[TP_MENU] = (KitsunePadRect){ fcx - shw / 2, faceTop - 0.35 * u - shh, shw, shh };
    }
    return u;
}

#endif

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "windef.h"
#include "wingdi.h"

#define TRACE(...) ((void)0)
#define ERR(...) ((void)0)
#define NEXT_DEVMODEW(m) ((DEVMODEW *)((char *)(m) + (m)->dmSize + (m)->dmDriverExtra))
#include "wine-display-modes.inc"

static DEVMODEW mode(UINT w, UINT h)
{
    DEVMODEW m = { .dmSize = sizeof(m),
        .dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_BITSPERPEL |
                    DM_DISPLAYFREQUENCY | DM_DISPLAYORIENTATION,
        .dmPelsWidth = w, .dmPelsHeight = h, .dmBitsPerPel = 32,
        .dmDisplayFrequency = 60, .dmDisplayOrientation = DMDO_DEFAULT };
    return m;
}

int main(void)
{
    DEVMODEW physical = mode(1350, 624), stale = mode(294, 640), selected;
    UINT count, candidates = 0;
    DEVMODEW *modes = get_virtual_modes(&physical, &physical, &physical, 1, &count);
    assert(modes && count);
    selected = validate_mode(physical, stale, modes, count);
    assert(selected.dmPelsWidth == 1350 && selected.dmPelsHeight == 624);
    for (UINT i = 0; i < count; i++)
        if (modes[i].dmBitsPerPel == 32 && modes[i].dmPelsWidth >= 800 &&
            modes[i].dmPelsHeight >= 600 && modes[i].dmPelsWidth <= selected.dmPelsWidth &&
            modes[i].dmPelsHeight <= selected.dmPelsHeight) candidates++;
    assert(candidates >= 2); /* Native and 800x600 survive DSR's filtering. */
    selected = validate_mode(physical, mode(800, 600), modes, count);
    assert(selected.dmPelsWidth == 800 && selected.dmPelsHeight == 600);
    selected = validate_mode(physical, physical, modes, count);
    assert(selected.dmPelsWidth == 1350 && selected.dmPelsHeight == 624);
    selected = validate_mode(physical, mode(1920, 1080), modes, count);
    assert(selected.dmPelsWidth == 1350 && selected.dmPelsHeight == 624);
    stale = mode(800, 600);
    stale.dmDisplayOrientation = DMDO_90;
    selected = validate_mode(physical, stale, modes, count);
    assert(selected.dmPelsWidth == 1350 && selected.dmPelsHeight == 624);
    free(modes);
    puts("DISPLAY-MODES PASS: stale portrait/oversized/rotated modes rejected; native and 800x600 retained");
    return 0;
}

#!/usr/bin/env bash
# Host regression suite: Win32, x86-64, D3D11, GUI, input and packaging checks
# run under build/kitsune-host; exits non-zero if any fail. Requires DECOY_DIR
# pointing at the layout from 20-decoy-split.sh, which builds the test programs,
# and the prefix template from 17-prefix-template.sh.
# REGRESS_{D3D,GUI,FPS}_SECONDS override run lengths.
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEST="${DECOY_DIR:?set DECOY_DIR}"
PE="$DEST/tree/lib/wine/aarch64-windows"
TESTS="$DEST/tests"
HOST="$ROOT/build/kitsune-host"
TMPL="$ROOT/out/wine-core/prefix-template"
EXPECT_HASH="2236d88fe5618cef"
EXPECT_SEH="OK checksum=94a514d4d6110800"
fails=0

for f in hello64 seh64 sehcross64 inputprobe fpsprobe d3d11_rb d3d11_swap d3d11_swap64; do
  [ -f "$PE/$f.exe" ] || die "no $f.exe in $PE; run 20-decoy-split.sh"
done
for f in process-parent-arm64 process-parent-x64 child-pool-x64; do
  [ -f "$TESTS/$f.exe" ] || die "no $f.exe in $TESTS; run 20-decoy-split.sh"
done
[ -f "$DEST/bundle/lib/wine/aarch64-windows/kitsune-session.exe" ] \
  || die "no session host in $DEST/bundle; run 20-decoy-split.sh"
[ -f "$TMPL/system.reg" ] || die "no prefix template; run 17-prefix-template.sh"

run() {  # run <label> <env...> -- <argv...>
  local label="$1"; shift
  KITSUNE_UNIX="$DEST/bundle" KITSUNE_TREE="$DEST/tree" "$@" </dev/null 2>/dev/null || true
}

check() {  # check <label> <expected-substring> <output>
  if printf '%s' "$3" | grep -qa -- "$2"; then
    printf '  \033[1;32mPASS\033[0m %s\n' "$1"
  else
    printf '  \033[1;31mFAIL\033[0m %s (no %s in: %s)\n' "$1" "$2" "$(printf '%s' "$3" | tr '\n' ' ' | cut -c1-120)"
    fails=$((fails + 1))
  fi
}

log "regression suite"

# --- the emulator that runs is libarm64ecfex.dll, not xtajit64.dll -----------
# find_builtin_dll maps the builtin by its real name while traces still print
# xtajit64.dll, so an emulator copied onto xtajit64.dll alone never runs.
for t in "$PE" "$ROOT/out/wine-core/lib/wine/aarch64-windows"; do
  [ -f "$t/xtajit64.dll" ] && [ -f "$t/libarm64ecfex.dll" ] || continue
  if cmp -s "$t/xtajit64.dll" "$t/libarm64ecfex.dll"; then
    printf '  \033[1;32mPASS\033[0m emulator aliases agree in %s\n' "$(basename "$(dirname "$t")")"
  else
    printf '  \033[1;31mFAIL\033[0m xtajit64.dll != libarm64ecfex.dll in %s -- the SECOND one is what runs\n' "$t"
    fails=$((fails + 1))
  fi
done

# The forced pass routes every allocation through the iOS fallback that device
# x86-64 depends on; the harness's own search always succeeds without it.
for mode in normal forced; do
  if [ "$mode" = forced ]; then export WINE_IOS_FORCE_KERNEL_MAP=1; else unset WINE_IOS_FORCE_KERNEL_MAP; fi

  out=$(run cmd env WINEDEBUG=-all "$HOST" "$PE/cmd.exe" /c ver)
  check "cmd.exe [$mode]" "Microsoft Windows" "$out"

  out=$(run x86 env WINEDEBUG=-all "$HOST" "$PE/hello64.exe")
  check "x86-64 under FEX [$mode]" "$EXPECT_HASH" "$out"

  # A context restored with the wrong FEX state register or TEB slot does not
  # crash here; it yields a wrong checksum.
  out=$(run seh env WINEDEBUG=-all "$HOST" "$PE/seh64.exe")
  check "x86-64 exception+resume [$mode]" "$EXPECT_SEH" "$out"

  # The fault is in EC code and the handler in an x86 frame with hand-written
  # unwind data; seh64's vectored handler runs before any frame-based search.
  out=$(run sehcross env WINEDEBUG=-all "$HOST" "$PE/sehcross64.exe")
  check "x86 handler across EC boundary [$mode]" "seh-cross: OK handler reached" "$out"
done
unset WINE_IOS_FORCE_KERNEL_MAP

# --- child processes, run as threads the way the app runs them ---------------
# The child also loads an API set and a system directory path, which name no
# file in the prefix (Steam's web helper dies without the API set).
for arch in arm64 x64; do
  out=$(KITSUNE_UNIX="$DEST/bundle" KITSUNE_TREE="$DEST/tree" \
        KITSUNE_PROCESS_CACHE_EXPERIMENT=1 KITSUNE_THREADED_PROCESS=1 \
        env WINEDEBUG=-all "$HOST" "$TESTS/process-parent-$arch.exe" </dev/null 2>&1 || true)
  check "threaded child boots and loads system modules [$arch]" "PROCESS-GATE PASS" "$out"
done
# Errors stay on as in the app: the release path logs from a thread without
# Wine thread data, which used to kill the process.
out=$(KITSUNE_UNIX="$DEST/bundle" KITSUNE_TREE="$DEST/tree" \
      KITSUNE_PROCESS_CACHE_EXPERIMENT=1 KITSUNE_THREADED_PROCESS=1 \
      WINE_IOS_BIGPOOL_MB=1 WINE_IOS_CEF_LOWBAND=1 \
      env WINEDEBUG=fixme-all "$HOST" "$TESTS/child-pool-x64.exe" </dev/null 2>&1 || true)
check "the app outlives a child holding a soft pool" "CHILD-POOL PASS" "$out"
# What a child allocated comes back when it exits: 256 MB (a mid-size band
# member), a DLL and 150 thread lifetimes, more than the reaper once tracked.
out=$(KITSUNE_UNIX="$DEST/bundle" KITSUNE_TREE="$DEST/tree" \
      KITSUNE_PROCESS_CACHE_EXPERIMENT=1 KITSUNE_THREADED_PROCESS=1 \
      env WINEDEBUG=-all "$HOST" "$TESTS/child-reclaim-parent.exe" </dev/null 2>&1 || true)
check "a child's memory comes back when it exits" "CHILD-RECLAIM PASS" "$out"
check "a retired child's cached descriptors are closed" "cached descriptors for retired child" "$out"
# A game started by Steam runs without Steam's web helper (KITSUNE_STEAM_LEAN):
# stand-ins named like Steam's processes, in Steam's layout.
out=$(KITSUNE_STEAM_LEAN=1 KITSUNE_UNIX="$DEST/bundle" KITSUNE_TREE="$DEST/tree" \
      KITSUNE_PROCESS_CACHE_EXPERIMENT=1 KITSUNE_THREADED_PROCESS=1 \
      env WINEDEBUG=-all "$HOST" "$TESTS/lean/steam.exe" </dev/null 2>&1 || true)
check "Steam's web helper is ended for a game and back after it" "STEAM-LEAN PASS" "$out"

# --- the session: its host starts what the app queues ------------------------
# The harness plays the app's part (KITSUNE_SESSION_LAUNCH) and exits once no
# program is left, since the host itself never exits.
SESSION_HOST="$DEST/bundle/lib/wine/aarch64-windows/kitsune-session.exe"
prog=$(python3 -c 'import sys; print("Z:" + sys.argv[1].replace("/", "\\"))' "$PE/fpsprobe.exe")
out=$(KITSUNE_UNIX="$DEST/bundle" KITSUNE_TREE="$DEST/tree" \
      KITSUNE_PROCESS_CACHE_EXPERIMENT=1 KITSUNE_THREADED_PROCESS=1 WINE_DISPLAY_DRIVER=ios \
      KITSUNE_FPS_SECONDS=2 KITSUNE_SESSION_LAUNCH="$prog" \
      env WINEDEBUG=-all "$HOST" "$SESSION_HOST" </dev/null 2>&1 || true)
check "the session host starts a queued program" "harness: session running" "$out"
check "the session goes idle when the program exits" "harness: session idle" "$out"

# A rotation sends WM_DISPLAYCHANGE to the desktop window and waits for the
# session host, which owns it, to answer. The app rotates twice at a game's
# launch (portrait, then landscape): both must land, and input must follow.
prog=$(python3 -c 'import sys; print("Z:" + sys.argv[1].replace("/", "\\"))' "$PE/inputprobe.exe")
out=$(KITSUNE_UNIX="$DEST/bundle" KITSUNE_TREE="$DEST/tree" KITSUNE_HOST_SURFACE=1 \
      KITSUNE_PROCESS_CACHE_EXPERIMENT=1 KITSUNE_THREADED_PROCESS=1 WINE_DISPLAY_DRIVER=ios \
      KITSUNE_TEST_INPUT=1 KITSUNE_TEST_SCREEN_CHANGE=780x1526,1275x629 KITSUNE_PROBE_SECONDS=22 \
      KITSUNE_SESSION_LAUNCH="$prog" \
      env WINEDEBUG=-all,err+wineios "$HOST" "$SESSION_HOST" </dev/null 2>&1 || true)
check "a second rotation reaches Wine" "screen changed to 1275x629" "$out"
check "input arrives after rotations" "clip=0,0-1275,629" "$out"

# --- D3D11 through DXMT ------------------------------------------------------
# Renders offscreen and checks its own pixels, so it needs no compositor.
out=$(WINEDLLOVERRIDES='d3d11,dxgi,d3d10core=b' WINE_DISPLAY_DRIVER=ios \
      KITSUNE_UNIX="$DEST/bundle" KITSUNE_TREE="$DEST/tree" \
      env WINEDEBUG=-all "$HOST" "$PE/d3d11_rb.exe" </dev/null 2>/dev/null || true)
check "D3D11 triangle via DXMT" "OK triangle rendered" "$out"

# --- D3D11 through a swapchain, as a game uses it ----------------------------
# Covers the windowed path: IDXGISwapChain -> DXMT Presenter ->
# CreateMetalViewFromHWND -> the macdrv_functions bridge -> a CAMetalLayer.
for swap in d3d11_swap.exe d3d11_swap64.exe; do
  arch=arm64ec; [ "$swap" = d3d11_swap64.exe ] && arch=x86-64
  out=$(WINEDLLOVERRIDES='d3d11,dxgi,d3d10core=b' WINE_DISPLAY_DRIVER=ios \
        KITSUNE_UNIX="$DEST/bundle" KITSUNE_TREE="$DEST/tree" \
        KITSUNE_D3D_SECONDS="${REGRESS_D3D_SECONDS:-3}" KITSUNE_D3D_CBUF=1 \
        env WINEDEBUG=-all "$HOST" "$PE/$swap" </dev/null 2>/dev/null || true)
  check "D3D11 swapchain presents [$arch]" "OK swapchain presented" "$out"
  check "D3D11 swapchain back buffer has the triangle [$arch]" "centre=red corner=blue" "$out"
  # Releasing calls ReleaseMetalView; catches a double free of the overlay.
  check "D3D11 swapchain tears down cleanly [$arch]" "d3d11-swap: released" "$out"
  printf '       %s\n' "$(printf '%s' "$out" | grep -a 'fps' | tail -1)"
done

# --- the composited screen ---------------------------------------------------
# KITSUNE_HOST_SURFACE=1 gives the driver its device-side host hooks and
# composites the layers offscreen (see src/host/host_surface.m). WINEIOS_CAPTURE
# cannot replace this: it sees only the GDI path, which DXMT's overlay bypasses.
comp="$DEST/regress-composite.ppm"
rm -f "$comp"
out=$(WINEDLLOVERRIDES='d3d11,dxgi,d3d10core=b' WINE_DISPLAY_DRIVER=ios \
      KITSUNE_HOST_SURFACE=1 KITSUNE_HOST_COMPOSITE="$comp" \
      KITSUNE_UNIX="$DEST/bundle" KITSUNE_TREE="$DEST/tree" \
      KITSUNE_D3D_SECONDS="${REGRESS_D3D_SECONDS:-3}" KITSUNE_D3D_CBUF=1 \
      env WINEDEBUG=-all "$HOST" "$PE/d3d11_swap.exe" </dev/null 2>&1 || true)

# Sample points come from the compositor's report of the window rather than
# fixed coordinates, because the window's position is itself under test. Only
# reports from before the program stops presenting count: one taken between
# the overlay's teardown and the window's shows a black GDI layer on top.
scr=$(printf '%s' "$out" | sed '/OK swapchain presented/q' | grep -a 'wineios:host: screen hwnd' | tail -1)
check "composited screen: D3D overlay is the topmost layer" "top=overlay" "$scr"

centre=$(printf '%s' "$scr" | sed -n 's/.*centre=\([0-9a-f][0-9a-f]*\).*/\1/p')
corner=$(printf '%s' "$scr" | sed -n 's/.*corner=\([0-9a-f][0-9a-f]*\).*/\1/p')
if [ ${#centre} -eq 6 ] && [ ${#corner} -eq 6 ]; then
  cr=$((16#${centre:0:2})); cg=$((16#${centre:2:2})); cb=$((16#${centre:4:2}))
  kb=$((16#${corner:4:2})); kr=$((16#${corner:0:2}))
  # Same thresholds as the guest's back-buffer check: red centre, blue corner.
  if [ "$cr" -gt 200 ] && [ "$cg" -lt 60 ] && [ "$cb" -lt 60 ] &&
     [ "$kb" -gt 200 ] && [ "$kr" -lt 60 ]; then
    printf '  \033[1;32mPASS\033[0m composited screen has the triangle (centre=%s corner=%s)\n' \
           "$centre" "$corner"
  else
    printf '  \033[1;31mFAIL\033[0m composited screen: centre=%s corner=%s (want red over blue)\n' \
           "$centre" "$corner"
    fails=$((fails + 1))
  fi
else
  printf '  \033[1;31mFAIL\033[0m composited screen: no readout from the host compositor\n'
  fails=$((fails + 1))
fi

# host_surface.m reports presentsWithTransaction on the DXMT overlay, a
# setting only the real compositor reacts to.
if printf '%s' "$out" | grep -qa 'wineios:host: FAIL'; then
  printf '  \033[1;31mFAIL\033[0m %s\n' \
         "$(printf '%s' "$out" | grep -a 'wineios:host: FAIL' | head -1 | cut -c1-160)"
  fails=$((fails + 1))
else
  printf '  \033[1;32mPASS\033[0m overlay layer is configured for the presenter that owns it\n'
fi

[ -s "$comp" ] || { printf '  \033[1;31mFAIL\033[0m no composite image written\n'; fails=$((fails + 1)); }

# --- GUI: window plus glyphs -------------------------------------------------
cap="$DEST/regress-cap"
rm -rf "$cap"; mkdir -p "$cap"
WINEIOS_CAPTURE="$cap/np" WINE_DISPLAY_DRIVER=ios WINEDEBUG=-all \
  KITSUNE_UNIX="$DEST/bundle" KITSUNE_TREE="$DEST/tree" \
  "$HOST" "$PE/notepad.exe" </dev/null >"$cap/log" 2>&1 &
gui_pid=$!
sleep "${REGRESS_GUI_SECONDS:-35}"
kill -9 $gui_pid 2>/dev/null || true
wait $gui_pid 2>/dev/null || true

frames=$(ls "$cap"/*.ppm 2>/dev/null | wc -l | tr -d ' ')
if [ "$frames" -gt 0 ]; then
  printf '  \033[1;32mPASS\033[0m notepad rendered %s frames\n' "$frames"
else
  printf '  \033[1;31mFAIL\033[0m notepad rendered no frames\n'; fails=$((fails + 1))
fi

# Glyph check without OCR: the menu strip is flat #d4d0c8 until its text is
# drawn, so dark pixels there mean glyphs rendered.
latest=$(ls -t "$cap"/*.ppm 2>/dev/null | head -1)
if [ -n "$latest" ]; then
  dark=$(/usr/bin/python3 - "$latest" <<'PYEOF'
import sys
d = open(sys.argv[1], 'rb').read()
_, dims, _, px = d.split(b'\n', 3)
w, h = map(int, dims.split())
n = 0
for y in range(26, min(44, h)):
    for x in range(5, min(220, w)):
        i = (y * w + x) * 3
        if (px[i] * 299 + px[i+1] * 587 + px[i+2] * 114) // 1000 < 100:
            n += 1
print(n)
PYEOF
)
  if [ "$dark" -gt 50 ]; then
    printf '  \033[1;32mPASS\033[0m menu bar has glyphs (%s dark px)\n' "$dark"
  else
    printf '  \033[1;31mFAIL\033[0m menu bar has no glyphs (%s dark px, expect >50)\n' "$dark"
    fails=$((fails + 1))
  fi
fi

# --- input reaches a guest window --------------------------------------------
# Asserts what the guest window received, not what the driver sent.
# KITSUNE_TEST_INPUT makes the harness inject five moves, a click at (640,300)
# and the 'A' key about 12 s in; the probe prints the coordinates it receives.
# stderr too: the driver's server-side readout (srv{...}) is printed there.
out=$(KITSUNE_TEST_INPUT=1 KITSUNE_PROBE_SECONDS=18 WINE_DISPLAY_DRIVER=ios \
      KITSUNE_UNIX="$DEST/bundle" KITSUNE_TREE="$DEST/tree" \
      env WINEDEBUG=-all "$HOST" "$PE/inputprobe.exe" </dev/null 2>&1 || true)
check "mouse reaches a guest window" "OK window received mouse" "$out"
check "mouse lands where it was aimed" "at=640,300" "$out"
check "keyboard reaches a guest window" "OK window received keyboard" "$out"

# Overlapping windows, as with a menu or dialog: Wine, not the host, must pick
# the top one for the click. A separate run, since the popup takes the focus.
pop=$(KITSUNE_TEST_INPUT=1 KITSUNE_PROBE_SECONDS=18 KITSUNE_PROBE_POPUP=1 \
      WINE_DISPLAY_DRIVER=ios KITSUNE_UNIX="$DEST/bundle" KITSUNE_TREE="$DEST/tree" \
      env WINEDEBUG=-all "$HOST" "$PE/inputprobe.exe" </dev/null 2>&1 || true)
check "click reaches the window on top" "OK popup got the click" "$pop"
# Chromium clears hover on WM_MOUSELEAVE; without it Steam's hover menus stay
# open. The cursor goes from the window onto the popup, then off the popup.
check "moving onto a window on top leaves the one below" "OK the window underneath was told the cursor left" "$pop"
check "moving off a popup leaves it" "OK the popup was told the cursor left" "$pop"

# TrackPopupMenu runs its own modal loop, takes capture and hit-tests itself;
# TPM_RETURNCMD makes it report the selected item.
men=$(KITSUNE_TEST_INPUT=1 KITSUNE_PROBE_SECONDS=20 KITSUNE_PROBE_MENU=1 \
      WINE_DISPLAY_DRIVER=ios KITSUNE_UNIX="$DEST/bundle" KITSUNE_TREE="$DEST/tree" \
      env WINEDEBUG=-all "$HOST" "$PE/inputprobe.exe" </dev/null 2>&1 || true)
check "a click selects a menu item" "OK menu took the click" "$men"

# A button is a child window; clicking one goes through win32u's activation
# path, which no other check here reaches.
ctl=$(KITSUNE_TEST_INPUT=1 KITSUNE_PROBE_SECONDS=18 KITSUNE_PROBE_BUTTON=1 \
      WINE_DISPLAY_DRIVER=ios KITSUNE_UNIX="$DEST/bundle" KITSUNE_TREE="$DEST/tree" \
      env WINEDEBUG=-all "$HOST" "$PE/inputprobe.exe" </dev/null 2>&1 || true)
check "click reaches a child control" "OK child control took the click" "$ctl"
# 65576 is the probe's top-level window. GA_ROOT is 0 when the desktop window
# is broken (get_win_ptr() in dlls/win32u/window.c), which drops the click.
check "GA_ROOT resolves for a child" "btn.GA_ROOT=65576" "$ctl"

# A window's CAMetalLayer must go in pDestroyWindow, or a closed dialog stays
# on screen. WINEIOS_METAL_DEBUG prints layer creation and destruction.
dst=$(KITSUNE_PROBE_SECONDS=14 KITSUNE_PROBE_POPUP=1 KITSUNE_PROBE_DESTROY=1 WINEIOS_METAL_DEBUG=1 \
      WINE_DISPLAY_DRIVER=ios KITSUNE_UNIX="$DEST/bundle" KITSUNE_TREE="$DEST/tree" \
      env WINEDEBUG=-all "$HOST" "$PE/inputprobe.exe" </dev/null 2>&1 || true)
check "a destroyed window takes its layer with it" "destroy layer" "$dst"

# Hidden, not destroyed, as Steam's menus are: the layer must leave the screen,
# or a closed menu stays drawn. The harness host prints a [hide] dump.
hid=$(KITSUNE_HOST_SURFACE=1 KITSUNE_PROBE_SECONDS=14 KITSUNE_PROBE_POPUP=1 KITSUNE_PROBE_HIDE=1 \
      WINE_DISPLAY_DRIVER=ios KITSUNE_UNIX="$DEST/bundle" KITSUNE_TREE="$DEST/tree" \
      env WINEDEBUG=-all "$HOST" "$PE/inputprobe.exe" </dev/null 2>&1 || true)
check "a hidden window's layer leaves the screen" "role gdi frame 540,200 200x200 px  hidden=1" "$hid"

# Message routing does not use WindowFromPoint, so it can break unnoticed;
# programs that hit-test themselves (drag and drop, tooltips) depend on it.
check "WindowFromPoint resolves" "hit=0x1" "$out"

# --- how fast a window can be painted ----------------------------------------
# fpsprobe.exe paints continuously; the driver's present count for an idle
# guest such as notepad only shows how often it paints. 30 fps is a floor, not
# a target: the real rate follows the display's refresh rate.
out=$(KITSUNE_UNIX="$DEST/bundle" KITSUNE_TREE="$DEST/tree" WINE_DISPLAY_DRIVER=ios \
      KITSUNE_FPS_SECONDS="${REGRESS_FPS_SECONDS:-3}" \
      env WINEDEBUG=-all "$HOST" "$PE/fpsprobe.exe" </dev/null 2>/dev/null || true)
line=$(printf '%s' "$out" | grep -a 'fps-probe: final' | tail -1)
fps=$(printf '%s' "$line" | awk '{print int($3)}')
if [ -n "$fps" ] && [ "$fps" -ge 30 ]; then
  printf '  \033[1;32mPASS\033[0m window paints at %s fps (floor 30)\n' "$fps"
  printf '       %s\n' "$line"
else
  printf '  \033[1;31mFAIL\033[0m window paint rate %s fps, floor 30 (%s)\n' "${fps:-none}" "$line"
  fails=$((fails + 1))
fi

# --- the prefix that ships in the tree ---------------------------------------
# The phone installs this prefix instead of running wineboot --init. hello64
# needs the CP 40xx CPU-feature keys wineboot writes and checks a hash, so a bad
# prefix fails here.
pfx="$DEST/template-prefix"
rm -rf "$pfx"; cp -R "$TMPL" "$pfx"
out=$(USER=wine KITSUNE_UNIX="$ROOT/build/host-tree" KITSUNE_TREE="$ROOT/out/wine-core" \
      KITSUNE_PREFIX="$pfx" env WINEDEBUG=-all "$HOST" "$PE/hello64.exe" </dev/null 2>/dev/null || true)
check "shipped prefix runs x86-64" "$EXPECT_HASH" "$out"

# The profile paths in system.reg are C:\users\$USER, so the template must use
# the user name the app also sets (wine).
if [ -d "$TMPL/drive_c/users/wine" ]; then
  printf '  \033[1;32mPASS\033[0m shipped prefix uses the portable user name\n'
else
  printf '  \033[1;31mFAIL\033[0m shipped prefix user dir is %s, expected wine\n' \
         "$(ls "$TMPL/drive_c/users" 2>/dev/null | tr '\n' ' ')"
  fails=$((fails + 1))
fi

echo
[ "$fails" -eq 0 ] && { log "all green"; exit 0; }
die "$fails regression(s)"

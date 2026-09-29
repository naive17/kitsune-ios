#!/usr/bin/env bash
# Build the device-shaped split layout that 21-regress.sh runs at $DECOY_DIR
# (default /tmp/decoy): build/host-tree with DXMT staged over it, the test
# programs 21 runs, and a prefix initialised by wineboot. Builds the test
# programs first. Requires 16-host-harness.sh and 10-dxmt.sh. The layout is a
# copy: rerun after every build.
set -euo pipefail
source "$(dirname "$0")/common.sh"

HOST_TREE="$ROOT/build/host-tree"
HOST_PE="$HOST_TREE/lib/wine/aarch64-windows"
# The layout's unix libraries load from the bundle, which is copied from here;
# the tree's copies are decoys that are never loaded.
HOST_UNIX="$HOST_TREE/lib/wine/aarch64-unix"
DXMT_OUT="$OUT/dxmt-arm64ec"
WINEMETAL_SO="$BUILD/dxmt-arm64ec/src/winemetal/unix/winemetal.so"
[ -d "$HOST_PE" ] || die "no build/host-tree; run 16-host-harness.sh"
[ -f "$DXMT_OUT/d3d11.dll" ] || die "no DXMT build; run 10-dxmt.sh"
[ -f "$WINEMETAL_SO" ] || die "no winemetal.so; run 10-dxmt.sh"

# --- test programs -----------------------------------------------------------
# DXMT and the D3D11 programs go into build/host-tree itself; the rest are
# copied into the layout below.
log "building the test programs"

# The 10-dxmt.sh build: the PE modules and the macOS winemetal.so. winemetal.so
# finds the display driver with dlsym(RTLD_DEFAULT, "macdrv_functions"), which
# wineios.drv exports and winemac.so does not.
for f in d3d11.dll d3d10core.dll dxgi.dll winemetal.dll; do
  cp "$DXMT_OUT/$f" "$HOST_PE/$f"
done
cp "$WINEMETAL_SO" "$HOST_UNIX/winemetal.so"
log "staged DXMT: 4 PE modules + winemetal.so"

# winemetal.so finds winemac.so and ntdll.so through an @loader_path/ rpath, so
# both must sit beside it; a missing one makes DXMT fail silently at run time.
if ! otool -L "$HOST_UNIX/winemetal.so" | grep -q "winemac.so"; then
  warn "winemetal.so no longer references winemac.so; check the link"
fi
for dep in winemac.so ntdll.so; do
  [ -f "$HOST_UNIX/$dep" ] || die "winemetal.so needs $dep and $HOST_UNIX has none"
done

mkdir -p "$BUILD/dxmt-tests"
: > "$BUILD/dxmt-tests/build.log"

# d3d11_rb renders offscreen and checks its own pixels; it needs no window.
# Every test program gets 64 KB section alignment, as the DXMT modules do
# (10-dxmt.sh): a 16 KB host page must not span two PE sections.
"$MINGW_BIN/arm64ec-w64-mingw32-clang" -O2 -o "$BUILD/dxmt-tests/d3d11_rb.exe" \
  "$ROOT/src/fex/d3d11-readback.c" \
  -Wl,--section-alignment=0x10000 \
  -ld3d11 -ld3dcompiler -ldxgi -lole32 \
  >> "$BUILD/dxmt-tests/build.log" 2>&1 \
  || { tail -20 "$BUILD/dxmt-tests/build.log"; die "d3d11_rb build failed"; }
cp "$BUILD/dxmt-tests/d3d11_rb.exe" "$HOST_PE/d3d11_rb.exe"

# d3d11_swap presents to a window through IDXGISwapChain, the path games use,
# and reports frames per second; the x86-64 build runs under FEX against the
# ARM64EC d3d11.dll.
for arch in arm64ec x86_64; do
  out="d3d11_swap.exe"; [ "$arch" = x86_64 ] && out="d3d11_swap64.exe"
  "$MINGW_BIN/$arch-w64-mingw32-clang" -O2 -o "$BUILD/dxmt-tests/$out" \
    "$ROOT/src/fex/d3d11-swapchain.c" \
    -Wl,--section-alignment=0x10000 \
    -ld3d11 -ld3dcompiler -ldxgi -lole32 -lgdi32 -luser32 \
    >> "$BUILD/dxmt-tests/build.log" 2>&1 \
    || { tail -20 "$BUILD/dxmt-tests/build.log"; die "$out build failed"; }
  cp "$BUILD/dxmt-tests/$out" "$HOST_PE/$out"
done
log "built d3d11_rb.exe, d3d11_swap.exe and d3d11_swap64.exe"

bash "$ROOT/src/fex/build-x64-guests.sh"
bash "$ROOT/src/guests/build-guests.sh"

# The child-process and child-pool programs, into build/process-tests. ARM64
# builds keep x28 free for the TEB, x64 guests keep their normal ABI under FEX.
PROCESS_TESTS="$BUILD/process-tests"
mkdir -p "$PROCESS_TESTS"
for role in parent child; do
  define=-DPROCESS_GATE_CHILD=0
  if test "$role" = child; then define=-DPROCESS_GATE_CHILD=1; fi
  "$MINGW_BIN/aarch64-w64-mingw32-clang" -O1 -ffixed-x28 -Wall -Wextra -Werror \
    -Wno-missing-field-initializers "$define" -nostdlib "$ROOT/tests/guest_process_test.c" \
    -Wl,--entry,mainCRTStartup -Wl,--subsystem,console -Wl,--section-alignment,0x10000 \
    -lkernel32 -o "$PROCESS_TESTS/process-$role-arm64.exe"
done
for role in parent child; do
  define=-DPROCESS_GATE_CHILD=0
  if test "$role" = child; then define=-DPROCESS_GATE_CHILD=1; fi
  "$MINGW_BIN/x86_64-w64-mingw32-clang" -O1 -Wall -Wextra -Werror \
    -Wno-missing-field-initializers "$define" '-DPROCESS_GATE_CHILD_NAME=L"process-child-x64.exe"' \
    -nostdlib "$ROOT/tests/guest_process_test.c" \
    -Wl,--entry,mainCRTStartup -Wl,--subsystem,console -Wl,--section-alignment,0x10000 \
    -lkernel32 -o "$PROCESS_TESTS/process-$role-x64.exe"
done
"$MINGW_BIN/x86_64-w64-mingw32-clang" -O1 -Wall -Wextra -Werror -Wno-missing-field-initializers \
  -nostdlib "$ROOT/tests/guest_child_pool_test.c" \
  -Wl,--entry,mainCRTStartup -Wl,--subsystem,console -Wl,--section-alignment,0x10000 \
  -lkernel32 -o "$PROCESS_TESTS/child-pool-x64.exe"
# A child's memory returned on exit: x64 like Steam's children, under FEX.
for role in parent child; do
  "$MINGW_BIN/x86_64-w64-mingw32-clang" -O1 -Wall -Wextra -Werror -Wno-missing-field-initializers \
    -DRECLAIM_CHILD=$([ "$role" = child ] && echo 1 || echo 0) -nostdlib "$ROOT/tests/guest_child_reclaim_test.c" \
    -Wl,--entry,mainCRTStartup -Wl,--subsystem,console -Wl,--section-alignment,0x10000 \
    -lkernel32 -o "$PROCESS_TESTS/child-reclaim-$role.exe"
done
# Steam without its UI during a game: stand-ins laid out like Steam's install.
mkdir -p "$PROCESS_TESTS/lean/steamapps/common/Game"
for role in 0 1 2; do
  case $role in
    0) out="$PROCESS_TESTS/lean/steam.exe";;
    1) out="$PROCESS_TESTS/lean/steamwebhelper.exe";;
    2) out="$PROCESS_TESTS/lean/steamapps/common/Game/game.exe";;
  esac
  "$MINGW_BIN/aarch64-w64-mingw32-clang" -O1 -ffixed-x28 -Wall -Wextra -Werror \
    -Wno-missing-field-initializers -DLEAN_ROLE=$role -nostdlib "$ROOT/tests/guest_steam_lean_test.c" \
    -Wl,--entry,mainCRTStartup -Wl,--subsystem,console -Wl,--section-alignment,0x10000 \
    -lkernel32 -o "$out"
done

DEST="${DECOY_DIR:-/tmp/decoy}"
rm -rf "$DEST"
mkdir -p "$DEST/bundle/lib/wine" "$DEST/tree/lib/wine"

# --- bundle: the signed .app, the only copy iOS can dlopen -----------------
cp -R "$HOST_TREE/lib/wine/aarch64-unix" "$DEST/bundle/lib/wine/"
cp -R "$HOST_TREE/share" "$DEST/bundle/"
# load_ntdll resolves these relative to ntdll.so's own directory, before any
# Documents tree is consulted, so the bundle must carry them. The display
# driver's PE half and the session host ship in the bundle as well.
mkdir -p "$DEST/bundle/lib/wine/aarch64-windows"
for f in ntdll.dll apisetschema.dll wineios.drv; do
  cp "$HOST_TREE/lib/wine/aarch64-windows/$f" "$DEST/bundle/lib/wine/aarch64-windows/"
done
bash "$ROOT/scripts/build-session-host.sh" "$DEST/bundle/lib/wine/aarch64-windows"

# --- tree: the Wine tree in Documents ---------------------------------------
# It carries the unix halves as the phone's tree does, but as text, so loading
# one from here instead of the bundle always fails.
cp -R "$HOST_TREE/lib/wine/aarch64-windows" "$DEST/tree/lib/wine/"
cp -R "$HOST_TREE/share" "$DEST/tree/"
mkdir -p "$DEST/tree/lib/wine/aarch64-unix"
for f in "$HOST_TREE"/lib/wine/aarch64-unix/*.so; do
  printf 'decoy: iOS can never dlopen this copy; the bundle must win\n' \
    > "$DEST/tree/lib/wine/aarch64-unix/$(basename "$f")"
done
cp "$BUILD/x64-guests/"*.exe "$BUILD/guests/"*.exe "$DEST/tree/lib/wine/aarch64-windows/"

# A parent test program starts its child from its own directory.
mkdir -p "$DEST/tests"
cp "$PROCESS_TESTS/"*.exe "$DEST/tests/"
cp -R "$PROCESS_TESTS/lean" "$DEST/tests/"

# --- prefix ------------------------------------------------------------------
# Recreating DEST removes the prefix, and without the CPU-feature keys wineboot
# writes, x86-64 dies in FEX with EXCEPTION_ILLEGAL_INSTRUCTION.
log "initialising prefix (writes the CPU-feature keys FEX needs)"
IOSWINE_UNIX="$DEST/bundle" IOSWINE_TREE="$DEST/tree" \
  "$ROOT/build/ioswine-host" \
  "$DEST/tree/lib/wine/aarch64-windows/wineboot.exe" --init \
  </dev/null >"$DEST/wineboot.log" 2>&1 \
  || { tail -15 "$DEST/wineboot.log"; die "wineboot --init failed"; }
cp_keys=$(grep -ac 'CP 40' "$DEST/tree/prefix/system.reg" 2>/dev/null || echo 0)
[ "$cp_keys" -gt 0 ] || die "prefix has no CPU-feature keys; x86-64 will fail"
log "  prefix: $(ls "$DEST"/tree/prefix/*.reg | wc -l | tr -d ' ') .reg, $cp_keys CPU-feature keys"

log "decoy split at $DEST"
log "  bundle: $(ls "$DEST"/bundle/lib/wine/aarch64-unix/*.so | wc -l | tr -d ' ') loadable .so"
log "  tree:   $(ls "$DEST"/tree/lib/wine/aarch64-unix/*.so | wc -l | tr -d ' ') decoys"
log "  tests:  $(ls "$DEST"/tests/*.exe | wc -l | tr -d ' ') child-process programs"

#!/usr/bin/env bash
# Build DXMT (Direct3D 11 on Metal): the arm64ec PE modules d3d11, d3d10core,
# dxgi and winemetal, stamped as Wine builtins, into out/dxmt-arm64ec, and the
# macOS winemetal.so in build/dxmt-arm64ec, which 20-test-layout.sh stages for
# the host harness and 15-dxmt-ios.sh rebuilds for iOS.
# Requires 02-fetch.sh, 03-llvm15.sh and 07-wine-macos.sh.
source "$(dirname "$0")/common.sh"

SRC="$THIRD_PARTY/dxmt"
B="$BUILD/dxmt-arm64ec"
LLVM="$TOOLCHAINS/llvm15-macos"
WINE_BUILD="$BUILD/wine-macos"

[ -d "$SRC" ] || die "run 02-fetch.sh first"
[ -d "$LLVM/include/llvm" ] || die "LLVM 15 missing; run scripts/03-llvm15.sh"
[ -d "$WINE_BUILD" ] || die "wine build missing; run scripts/07-wine-macos.sh"

# DXMT requires LLVM major 15 exactly: AIR is versioned LLVM bitcode, and a
# newer bitcode writer emits modules Metal will not load.
ver="$(awk '/define LLVM_VERSION_MAJOR/{print $3}' "$LLVM/include/llvm/Config/llvm-config.h")"
[ "$ver" = "15" ] || die "need LLVM major 15, found $ver"
log "llvm15: $LLVM (major $ver)"

xcrun --sdk iphoneos metal --version >/dev/null 2>&1 \
  || warn "Metal toolchain not functional; winemetal.so needs it for its embedded shaders"

# The port is applied here rather than in 15-dxmt-ios.sh, which re-runs this
# build's commands: the PE modules and winemetal.so share a shader cache ABI and
# argument layouts, so every build must use the same patched sources.
bash "$ROOT/scripts/apply-dxmt-port.sh"

if [ ! -f "$B/build.ninja" ]; then
  log "configuring dxmt (arm64ec cross build)"
  # 64 KB section alignment, as Wine's builtins use: with the 4 KB PE default
  # one 16 KB host page can hold both code and the IAT, which the loader writes,
  # and the JIT arena cannot map a page executable and writable at once.
  # The C++ runtime is static because llvm-mingw's libc++.dll and libunwind.dll
  # are 4 KB-aligned prebuilts with the same problem.
  meson setup "$B" "$SRC" \
    --cross-file "$SRC/build-arm64ec.txt" \
    --buildtype release \
    -Dc_link_args="-Wl,--section-alignment=0x10000 -static-libgcc" \
    -Dcpp_link_args="-Wl,--section-alignment=0x10000 -static-libstdc++ -static-libgcc" \
    -Dnative_llvm_path="$LLVM" \
    -Dwine_build_path="$WINE_BUILD" \
    > "$BUILD/dxmt-configure.log" 2>&1 \
    || { tail -40 "$BUILD/dxmt-configure.log"; die "meson setup failed (see $BUILD/dxmt-configure.log)"; }
fi

log "building dxmt"
# The macOS winemetal.so (for the host harness, 20-test-layout.sh) links against
# the macOS Wine unix libraries; if it fails to build, this script fails.
ninja -C "$B" src/d3d11/d3d11.dll src/d3d10/d3d10core.dll src/dxgi/dxgi.dll src/winemetal/winemetal.dll \
  src/winemetal/unix/winemetal.so || die "DXMT build failed"

mkdir -p "$OUT/dxmt-arm64ec"
found=0
for f in src/d3d11/d3d11.dll src/d3d10/d3d10core.dll src/dxgi/dxgi.dll src/winemetal/winemetal.dll; do
  python3 "$ROOT/scripts/lib/stamp-builtin.py" "$B/$f" >/dev/null
  cp "$B/$f" "$OUT/dxmt-arm64ec/"
  log "  $(basename "$f") machine=$("$MINGW_BIN/llvm-readobj" --file-headers "$B/$f" | awk '/Machine:/{print $NF}') stamped"
  found=$((found+1))
done

[ "$found" -ge 1 ] || die "no DXMT PE DLLs produced"
log "DXMT PE modules staged in $OUT/dxmt-arm64ec"

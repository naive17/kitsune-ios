#!/usr/bin/env bash
# Build DXVK's d3d9, d3d10core, d3d11 and dxgi as PE DLLs into out/dxvk-$ARCH.
# ARCH defaults to arm64ec, so an x86-64 game's D3D calls run as native ARM64
# code rather than under FEX; ARCH=aarch64 builds plain ARM64 for comparison.
# Requires 02-fetch.sh and glslang.
source "$(dirname "$0")/common.sh"

ARCH="${ARCH:-arm64ec}"
CROSS="$ROOT/crossfiles/$ARCH-w64-mingw32.txt"
[ -f "$CROSS" ] || die "no cross file for ARCH=$ARCH"
SRC="$THIRD_PARTY/dxvk"
B="$BUILD/dxvk-$ARCH"
[ -d "$SRC" ] || die "run 02-fetch.sh first"

command -v glslang >/dev/null || die "glslang missing (brew install glslang)"

# dxbc-spirv and DXVK rely on transitive includes (<new>, <algorithm>) that
# llvm-mingw's libc++ does not provide.
apply_patch "$SRC/subprojects/dxbc-spirv" \
  "$ROOT/patches/dxbc-spirv/0001-include-new-for-std-launder.patch"
apply_patch "$SRC" \
  "$ROOT/patches/dxvk/0001-missing-includes-for-libcxx.patch"

if [ ! -f "$B/build.ninja" ]; then
  log "configuring dxvk ($ARCH)"
  meson setup "$B" "$SRC" \
    --cross-file "$CROSS" \
    --buildtype release \
    --prefix "$OUT/dxvk-$ARCH" \
    > "$BUILD/dxvk-$ARCH-configure.log" 2>&1 \
    || { tail -40 "$BUILD/dxvk-$ARCH-configure.log"; die "meson setup failed"; }
fi

log "building dxvk ($ARCH)"
ninja -C "$B" -j2

mkdir -p "$OUT/dxvk-$ARCH"
found=0
for d in d3d9 d3d10core d3d11 dxgi; do
  f="$(find "$B" -name "$d.dll" | head -1)"
  [ -n "$f" ] || { warn "missing $d.dll"; continue; }
  cp "$f" "$OUT/dxvk-$ARCH/"
  mach="$("$MINGW_BIN/llvm-readobj" --file-headers "$f" | awk '/Machine:/{print $NF}')"
  log "  $d.dll machine=$mach"
  found=$((found+1))
done
[ "$found" -eq 4 ] || die "expected 4 DXVK DLLs, got $found"
log "DXVK ($ARCH) built: 4 DLLs in $OUT/dxvk-$ARCH"

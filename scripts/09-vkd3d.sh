#!/usr/bin/env bash
# Build vkd3d-proton's d3d12 and d3d12core (Direct3D 12 on Vulkan) as PE DLLs
# into out/vkd3d-$ARCH; ARCH defaults to arm64ec, as in 08-dxvk.sh.
# Requires 02-fetch.sh, glslang and widl from 07-wine-macos.sh.
source "$(dirname "$0")/common.sh"

ARCH="${ARCH:-arm64ec}"
CROSS="$ROOT/crossfiles/$ARCH-w64-mingw32.txt"
SRC="$THIRD_PARTY/vkd3d-proton"
B="$BUILD/vkd3d-$ARCH"
[ -d "$SRC" ] || die "run 02-fetch.sh first"
command -v glslang >/dev/null || die "glslang missing (brew install glslang)"

# The same llvm-mingw libc++ missing-include fixes as in 08-dxvk.sh.
apply_patch "$SRC/subprojects/dxil-spirv/subprojects/dxbc-spirv" \
  "$ROOT/patches/dxbc-spirv/0001-include-new-for-std-launder.patch"
apply_patch "$SRC/subprojects/dxil-spirv" \
  "$ROOT/patches/dxil-spirv/0001-include-exception-for-std-terminate.patch"

WIDL="$BUILD/wine-macos/tools/widl/widl"
[ -x "$WIDL" ] || die "widl not found at $WIDL; run 07-wine-macos.sh first"
mkdir -p "$BUILD/hostbin"
ln -sf "$WIDL" "$BUILD/hostbin/widl"
export PATH="$BUILD/hostbin:$PATH"
log "using widl: $WIDL"

if [ ! -f "$B/build.ninja" ]; then
  log "configuring vkd3d-proton ($ARCH)"
  meson setup "$B" "$SRC" \
    --cross-file "$CROSS" \
    --buildtype release \
    --prefix "$OUT/vkd3d-$ARCH" \
    > "$BUILD/vkd3d-$ARCH-configure.log" 2>&1 \
    || { tail -40 "$BUILD/vkd3d-$ARCH-configure.log"; die "meson setup failed"; }
fi

log "building vkd3d-proton ($ARCH)"
ninja -C "$B" -j4

mkdir -p "$OUT/vkd3d-$ARCH"
found=0
for d in d3d12 d3d12core; do
  f="$(find "$B" -name "$d.dll" | head -1)"
  [ -n "$f" ] || { warn "missing $d.dll"; continue; }
  cp "$f" "$OUT/vkd3d-$ARCH/"
  log "  $d.dll machine=$("$MINGW_BIN/llvm-readobj" --file-headers "$f" | awk '/Machine:/{print $NF}')"
  found=$((found+1))
done
[ "$found" -ge 1 ] || die "no vkd3d DLLs produced"
log "vkd3d-proton ($ARCH) built: $found DLLs in $OUT/vkd3d-$ARCH"

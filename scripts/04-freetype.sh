#!/usr/bin/env bash
# FreeType, which win32u needs to render any text, as static archives:
# out/freetype-macos for the host harness and out/freetype-ios for the app.
# Fetches the pinned source; needs cmake, ninja and the iPhoneOS SDK.
#
# Static because the port links it into win32u's unix half: under
# WINE_IOS_JIT_ARENA, freetype.c binds the FreeType functions directly instead
# of dlopen()ing a library. The optional dependencies are disabled so that none
# of them has to be built for iOS as well.
set -euo pipefail
source "$(dirname "$0")/common.sh"

SRC="$THIRD_PARTY/freetype"
pin_clone "$FREETYPE_URL" "$FREETYPE_SHA" "$SRC"

build_one() {
  local name="$1"; shift
  local bdir="$BUILD/freetype-$name"
  local idir="$OUT/freetype-$name"

  rm -rf "$bdir"
  cmake -S "$SRC" -B "$bdir" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_INSTALL_PREFIX="$idir" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DFT_DISABLE_ZLIB=TRUE \
    -DFT_DISABLE_BZIP2=TRUE \
    -DFT_DISABLE_PNG=TRUE \
    -DFT_DISABLE_HARFBUZZ=TRUE \
    -DFT_DISABLE_BROTLI=TRUE \
    "$@" > "$BUILD/freetype-$name.log" 2>&1 \
    || { tail -20 "$BUILD/freetype-$name.log"; die "freetype $name configure failed"; }

  cmake --build "$bdir" --target install >> "$BUILD/freetype-$name.log" 2>&1 \
    || { tail -20 "$BUILD/freetype-$name.log"; die "freetype $name build failed"; }

  local lib="$idir/lib/libfreetype.a"
  [ -f "$lib" ] || die "freetype $name: no libfreetype.a"
  log "  freetype-$name: $(du -h "$lib" | cut -f1)  $(lipo -archs "$lib" 2>/dev/null || echo '?')"
}

build_one macos \
  -DCMAKE_OSX_ARCHITECTURES=arm64

IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
build_one ios \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT="$IOS_SDK" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0

log "freetype staged: $OUT/freetype-macos, $OUT/freetype-ios"

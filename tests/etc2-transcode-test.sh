#!/bin/bash
# Encode solid colours with winemetal's ETC2/EAC transcoder and check that the
# Mac's GPU (which decodes ETC2 like the phone's) returns the same colours.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/third_party/dxmt/src/winemetal/unix"
[ -f "$SRC/bc_transcode.cpp" ] || { echo "SKIP: no DXMT checkout"; exit 0; }
OUT="$ROOT/.deploy/tests/etc2"
mkdir -p "$OUT"
# Not -I$SRC/etcpak: on a case-insensitive disk <version> would find etcpak/VERSION.
for f in bc_transcode.cpp etcpak/ProcessRGB.cpp etcpak/Tables.cpp etcpak/Dither.cpp; do
  xcrun clang++ -std=c++17 -O2 -w -c "$SRC/$f" -I"$SRC" -o "$OUT/$(basename "$f" .cpp).o"
done
xcrun clang -fobjc-arc -framework Metal -framework Foundation "$ROOT/tests/etc2_decode.m" \
  "$OUT/bc_transcode.o" "$OUT/ProcessRGB.o" "$OUT/Tables.o" "$OUT/Dither.o" -lc++ -o "$OUT/etc2_decode"
"$OUT/etc2_decode"

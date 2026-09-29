#!/usr/bin/env bash
# Check Wine's DirectWrite FreeType backend on the Mac with its iOS static
# binding (WINE_IOS_JIT_ARENA); 11-wine-ios.sh covers the iOS link itself.
# Builds tests/dwrite_backend_test.c against the built tree, and skips until
# scripts/setup.sh has built one.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ft_prefix=/opt/homebrew/opt/freetype
for f in third_party/wine/dlls/dwrite/freetype.c build/wine-macos/include/config.h \
         build/wine-ios/include/dwrite_3.h out/wine-core/share/wine/fonts/tahoma.ttf \
         "$ft_prefix/lib/libfreetype.dylib"; do
  [ -f "$f" ] || { echo "SKIP dwrite-backend: no $f (scripts/setup.sh)"; exit 0; }
done
mkdir -p .deploy/tests
xcrun --sdk macosx clang -O1 -g -D__WINESRC__ -DWINE_UNIX_LIB \
  -DWINE_IOS_JIT_ARENA -DWINE_NO_DEBUG_MSGS -DWINE_NO_TRACE_MSGS \
  -Ibuild/wine-macos/include -Ibuild/wine-ios/include -Ithird_party/wine/include \
  -Ithird_party/wine/dlls/dwrite -I"$ft_prefix/include/freetype2" \
  tests/dwrite_backend_test.c -L"$ft_prefix/lib" -lfreetype \
  -o .deploy/tests/dwrite-backend-test
.deploy/tests/dwrite-backend-test out/wine-core/share/wine/fonts/tahoma.ttf

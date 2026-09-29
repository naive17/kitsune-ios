#!/usr/bin/env bash
# Build DXMT's unix half, winemetal.so, for iOS into out/ios-unix, and stage the
# DXMT PE modules into out/wine-core. Requires 10-dxmt.sh, TARGET=ios
# 03-llvm15.sh, 11-wine-ios.sh and 14-core-tree.py.
#
# Meson cannot build it: winemetal.so is a `native:` target, and meson rejects
# a native compiler whose test program cannot run on the build machine. Instead
# the macOS build's own commands (`ninja -t commands`) are re-run with an iOS
# compiler, iOS libraries and an iOS Metal target.
set -euo pipefail
source "$(dirname "$0")/common.sh"

B_MAC="$BUILD/dxmt-arm64ec"
# A sibling of the physical dxmt-arm64ec directory, so the relative paths in
# the lifted commands (../../third_party/dxmt/...) resolve unchanged.
B_IOS="$(cd "$BUILD/dxmt-arm64ec" && pwd -P)/../dxmt-ios"
mkdir -p "$B_IOS"
LLVM_IOS="$TOOLCHAINS/llvm15-ios"
NTDLL_IOS="$BUILD/wine-ios/dlls/ntdll/ntdll.so"
# IOS_MIN must be at least 16.3: airconv's std::format uses libc++'s
# floating-point to_chars, an availability error (not a warning) before 16.3.
IOS_MIN=17.0
AIR_MIN=16.0
TARGET_SO="src/winemetal/unix/winemetal.so"

[ -f "$B_MAC/build.ninja" ]  || die "no macOS DXMT build; run 10-dxmt.sh"
[ -d "$LLVM_IOS/lib" ]       || die "no iOS LLVM 15; run TARGET=ios 03-llvm15.sh"
[ -f "$NTDLL_IOS" ]          || die "no iOS ntdll.so at $NTDLL_IOS; run 11-wine-ios.sh"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)" || die "no iPhoneOS SDK"
CLANG="$(xcrun -f clang)"
CLANGXX="$(xcrun -f clang++)"

log "iOS SDK: $(basename "$SDK")"

# The lifted commands call the compiler as `cc` and `c++`, so a PATH shim
# retargets it to iOS without editing them.
mkdir -p "$B_IOS/bin"
for pair in "cc:$CLANG" "c++:$CLANGXX"; do
  name="${pair%%:*}"; real="${pair#*:}"
  cat > "$B_IOS/bin/$name" <<SHIM
#!/bin/sh
exec "$real" -target arm64-apple-ios$IOS_MIN -isysroot "$SDK" "\$@"
SHIM
  chmod +x "$B_IOS/bin/$name"
done

RAW="$B_IOS/commands.mac.txt"
ninja -C "$B_MAC" -t commands "$TARGET_SO" > "$RAW" 2>/dev/null \
  || die "ninja could not list commands for $TARGET_SO"
n=$(wc -l < "$RAW" | tr -d ' ')
[ "$n" -ge 10 ] || die "only $n commands; the macOS build looks incomplete"
log "lifted $n commands from the macOS build"

# winemac.so is dropped: winemetal's only Wine import is NtSetEvent, from ntdll.
# ColorSync and Cocoa do not exist on iOS (patches/dxmt/0002 makes their users
# macOS-only); UIKit takes ColorSync's place in the link. macOS AIR does not
# load on iOS, so the embedded Metal shaders are retargeted.
GEN="$B_IOS/commands.ios.sh"
{
  printf '#!/bin/sh\nset -e\n'
  sed \
    -e "s|$TOOLCHAINS/llvm15-macos|$LLVM_IOS|g" \
    -e "s|$BUILD/wine-macos/dlls/winemac.drv/winemac.so||g" \
    -e "s|$BUILD/wine-macos/dlls/ntdll/ntdll.so|$NTDLL_IOS|g" \
    -e 's|-weak_framework ColorSync|-weak_framework UIKit|g' \
    -e 's|-weak_framework Cocoa||g' \
    -e 's|-sdk macosx|-sdk iphoneos|g' \
    -e "s|air64-apple-macos[0-9.]*|air64-apple-ios$AIR_MIN|g" \
    "$RAW"
} > "$GEN"
chmod +x "$GEN"

# sed ignores a pattern that does not match, and a missed substitution still
# builds a dylib that fails at run time, so check that each one landed.
for bad in "llvm15-macos" "winemac.so" "air64-apple-macos" "ColorSync"; do
  ! grep -q -- "$bad" "$GEN" || die "substitution missed: '$bad' still in $GEN"
done
grep -q -- "$LLVM_IOS" "$GEN"  || die "iOS LLVM path never appeared in $GEN"
grep -q -- "$NTDLL_IOS" "$GEN" || die "iOS ntdll.so never appeared in $GEN"
grep -q -- "air64-apple-ios"   "$GEN" || warn "no Metal shader targets found; upstream may have moved them"

log "building (this compiles airconv and the DXBC parser again, for iOS)"
( cd "$B_IOS"
  # Create the output directories, which ninja would otherwise have made.
  awk '{ for (i = 1; i <= NF; i++) if ($i == "-o") print $(i+1) }' "$GEN" \
    | sed 's|/[^/]*$||' | sort -u | while read -r d; do [ -n "$d" ] && mkdir -p "$d"; done
  PATH="$B_IOS/bin:$PATH" sh "$GEN"
) > "$BUILD/dxmt-ios.log" 2>&1 || { tail -30 "$BUILD/dxmt-ios.log"; die "build failed (see $BUILD/dxmt-ios.log)"; }

OUT_SO="$B_IOS/$TARGET_SO"
[ -f "$OUT_SO" ] || die "no winemetal.so produced"

# platform 2 is iOS. The `|| true` on each producer below stops SIGPIPE from
# an early-exiting grep failing the pipeline under pipefail.
plat=$( (otool -l "$OUT_SO" 2>/dev/null || true) | grep -m1 'platform' || true )
case "$plat" in
  *"platform 2"*) : ;;
  *) die "winemetal.so is not an iOS binary ($plat)" ;;
esac

( nm -u "$OUT_SO" 2>/dev/null || true ) | grep -q '_NtSetEvent' \
  || warn "winemetal.so does not import NtSetEvent; check the ntdll link"

# airconv stamps the metallibs it generates at run time with a triple from its
# source (patches/dxmt/0002), not from the compile target. A macOS triple there
# makes Metal reject every converted shader.
airtriples=$( (strings -a "$OUT_SO" 2>/dev/null || true) | grep -E '^air64-apple' | sort -u | tr '\n' ' ' )
case "$airtriples" in
  *macos*) die "generated AIR still targets macOS: $airtriples" ;;
  *ios*)   log "AIR triples: $airtriples" ;;
  *)       warn "no AIR triples found in winemetal.so; upstream may have changed how they are set" ;;
esac

log "winemetal.so: iOS arm64, $(du -h "$OUT_SO" | cut -f1), built and checked"

# winemetal.so goes into out/ios-unix, which is bundled into the signed app, as
# iOS loads dylibs only from a signed bundle. The PE files go into
# out/wine-core, the tree the app ships, so this runs after 14-core-tree.py.
UNIX_DST="$OUT/ios-unix"
PE_DST="$OUT/wine-core/lib/wine/aarch64-windows"

if [ -d "$UNIX_DST" ]; then
  cp "$OUT_SO" "$UNIX_DST/winemetal.so"
  log "bundle:  winemetal.so -> $UNIX_DST"
else
  warn "no $UNIX_DST, winemetal.so not staged; run 11-wine-ios.sh, then this script"
fi

if [ -d "$PE_DST" ]; then
  staged=0
  for f in d3d11.dll d3d10core.dll dxgi.dll winemetal.dll; do
    [ -f "$OUT/dxmt-arm64ec/$f" ] || { warn "no $f; run 10-dxmt.sh"; continue; }
    cp "$OUT/dxmt-arm64ec/$f" "$PE_DST/$f"
    staged=$((staged+1))
  done
  log "tree:    $staged PE files -> $PE_DST (scripts/18-stamp-tree.sh restamps it)"
else
  warn "no $PE_DST, DXMT PE files not staged; run 14-core-tree.py, then this script"
fi

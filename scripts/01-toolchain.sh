#!/usr/bin/env bash
# Install llvm-mingw (LLVM_MINGW_VER in pins.env) into toolchains/ and verify
# that its arm64ec driver emits genuine ARM64EC PEs.
source "$(dirname "$0")/common.sh"

mkdir -p "$TOOLCHAINS"
TC="$TOOLCHAINS/llvm-mingw-$LLVM_MINGW_VER"

if [ ! -x "$TC/bin/clang" ]; then
  require_disk_gb 5
  url="https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW_VER/$LLVM_MINGW_ASSET"
  log "downloading $LLVM_MINGW_ASSET"
  curl -fL --retry 3 -o "$TOOLCHAINS/$LLVM_MINGW_ASSET" "$url"
  log "extracting"
  tar -xJf "$TOOLCHAINS/$LLVM_MINGW_ASSET" -C "$TOOLCHAINS"
  mv "$TOOLCHAINS/${LLVM_MINGW_ASSET%.tar.xz}" "$TC" 2>/dev/null || true
  rm -f "$TOOLCHAINS/$LLVM_MINGW_ASSET"
fi
[ -x "$TC/bin/clang" ] || die "llvm-mingw extraction failed"

xattr -dr com.apple.quarantine "$TC" 2>/dev/null || true

log "llvm-mingw: $("$TC/bin/clang" --version | head -1)"

for t in aarch64-w64-mingw32-clang arm64ec-w64-mingw32-clang x86_64-w64-mingw32-clang; do
  [ -x "$TC/bin/$t" ] || die "missing target driver: $t"
  log "have $t"
done

work="$BUILD/toolchain-selftest"; rm -rf "$work"; mkdir -p "$work"
cat > "$work/t.c" <<'EOF'
__declspec(dllexport) int ios_wine_probe(int x) { return x * 3 + 1; }
EOF

log "self-test: arm64ec DLL"
"$TC/bin/arm64ec-w64-mingw32-clang" -shared -o "$work/probe_ec.dll" "$work/t.c" \
  || die "arm64ec-w64-mingw32-clang failed to link a DLL"

log "self-test: aarch64 DLL"
"$TC/bin/aarch64-w64-mingw32-clang" -shared -o "$work/probe_a64.dll" "$work/t.c" \
  || die "aarch64-w64-mingw32-clang failed to link a DLL"

# Without EC support the arm64ec DLL is plain ARM64 (0xAA64), like the other.
mach_ec="$("$TC/bin/llvm-readobj" --file-headers "$work/probe_ec.dll" | awk '/Machine:/{print $NF}')"
mach_a64="$("$TC/bin/llvm-readobj" --file-headers "$work/probe_a64.dll" | awk '/Machine:/{print $NF}')"
log "arm64ec machine=$mach_ec  aarch64 machine=$mach_a64"
[ "$mach_ec" != "$mach_a64" ] || die "arm64ec and aarch64 produced identical machine type - not a real EC build"

log "TOOLCHAIN SELF-TEST PASSED"

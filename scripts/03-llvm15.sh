#!/usr/bin/env bash
# Build LLVM 15's IR and bitcode libraries for the DXBC-to-AIR compiler in
# DXMT's unixlib, installed to toolchains/llvm15-$TARGET.
#   TARGET=macos scripts/03-llvm15.sh   host build (default); provides llvm-tblgen
#   TARGET=ios scripts/03-llvm15.sh     device build; needs the macos build first
source "$(dirname "$0")/common.sh"

TARGET="${TARGET:-macos}"   # macos | ios
SRC="$TOOLCHAINS/llvm-project"
B="$BUILD/llvm15-$TARGET"
PREFIX="$TOOLCHAINS/llvm15-$TARGET"

# A build takes about 0.3 GB and its install 0.2 GB.
mkdir -p "$B/"; require_disk_gb 3 "$B/"

if [ ! -d "$SRC/.git" ]; then
  log "cloning llvm-project @ $LLVM_AIR_TAG (shallow)"
  git clone --depth 1 --branch "$LLVM_AIR_TAG" \
    https://github.com/llvm/llvm-project.git "$SRC"
fi
have="$(git -C "$SRC" describe --tags 2>/dev/null || echo unknown)"
log "llvm source: $have"

# Use Xcode's compilers: /usr/bin/clang++ can resolve to the Command Line Tools,
# which lack the libc++ headers (see common.sh), and LLVM 15 then fails
# configure with a misleading libatomic error.
CC_BIN="$(xcrun -f clang)"   || die "xcrun cannot find clang"
CXX_BIN="$(xcrun -f clang++)" || die "xcrun cannot find clang++"
log "cc : $CC_BIN"

case "$TARGET" in
  macos)
    EXTRA=(-DCMAKE_OSX_ARCHITECTURES=arm64
           -DCMAKE_OSX_SYSROOT="$(xcrun --sdk macosx --show-sdk-path)"
           -DLLVM_HOST_TRIPLE=arm64-apple-darwin)
    ;;
  ios)
    SDKP="$(xcrun --sdk iphoneos --show-sdk-path)" || die "no iPhoneOS SDK"
    # llvm-tblgen runs during the build, so reuse the macOS build's copy. An iOS
    # tblgen fails at configure: "install TARGETS given no BUNDLE DESTINATION".
    HOSTTBL="$BUILD/llvm15-macos/bin/llvm-tblgen"
    [ -x "$HOSTTBL" ] || die "no host llvm-tblgen at $HOSTTBL; run TARGET=macos first"
    EXTRA=(-DCMAKE_SYSTEM_NAME=iOS
           -DCMAKE_OSX_SYSROOT="$SDKP"
           -DCMAKE_OSX_ARCHITECTURES=arm64
           -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
           -DLLVM_HOST_TRIPLE=arm64-apple-ios
           -DLLVM_TABLEGEN="$HOSTTBL"
           -DLLVM_INSTALL_UTILS=Off
           -DCMAKE_MACOSX_BUNDLE=Off
           # AddLLVM.cmake only recognises "Darwin", so for iOS it passes ld the
           # GNU --gc-sections. Dead-stripping is moot for static libraries.
           -DLLVM_NO_DEAD_STRIP=On
           # Tools and utils are not needed: airconv links the libraries
           # directly, without llvm-config.
           -DLLVM_INCLUDE_TOOLS=Off
           -DLLVM_INCLUDE_UTILS=Off
           -DLLVM_BUILD_UTILS=Off
           -DLLVM_INCLUDE_BENCHMARKS=Off)
    ;;
  *) die "TARGET must be macos or ios" ;;
esac

# Configure runs only once per build directory; remove $B after changing flags.
# DXMT needs only the IR and bitcode libraries; no backends, tools or tests.
if [ ! -f "$B/build.ninja" ]; then
  log "configuring LLVM 15 ($TARGET)"
  cmake -B "$B" -S "$SRC/llvm" -G Ninja \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_C_COMPILER="$CC_BIN" \
    -DCMAKE_CXX_COMPILER="$CXX_BIN" \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_ENABLE_ASSERTIONS=Off \
    -DLLVM_ENABLE_ZSTD=Off \
    -DLLVM_TARGETS_TO_BUILD="" \
    -DLLVM_BUILD_TOOLS=Off \
    -DLLVM_INCLUDE_TESTS=Off \
    -DLLVM_INCLUDE_EXAMPLES=Off \
    -DBUG_REPORT_URL="https://github.com/3Shain/dxmt" \
    -DPACKAGE_VENDOR="DXMT" \
    -DLLVM_VERSION_PRINTER_SHOW_HOST_TARGET_INFO=Off \
    "${EXTRA[@]}" \
    > "$BUILD/llvm15-$TARGET-configure.log" 2>&1 \
    || { tail -30 "$BUILD/llvm15-$TARGET-configure.log"; die "configure failed"; }
fi

log "building LLVM 15 ($TARGET) -j4 -- slow"
# -k 0 gets past LLVMHello, an example plugin that cannot link for iOS and is
# built even with LLVM_INCLUDE_EXAMPLES off. The checks below decide success.
cmake --build "$B" -j4 -- -k 0 || warn "some targets failed; checking the libraries"
cmake --install "$B" > /dev/null 2>&1 || warn "install reported errors; checking artifacts"

[ -d "$PREFIX/include/llvm" ] || die "install produced no headers"
for lib in libLLVMCore.a libLLVMBitWriter.a libLLVMSupport.a; do
  [ -f "$PREFIX/lib/$lib" ] || die "no $lib in $PREFIX/lib"
done
if [ "$TARGET" = ios ]; then
  # A macOS archive in the ios prefix passes the file test and fails only when
  # DXMT links. The || true guards keep otool's SIGPIPE (grep -m1 exits early)
  # from failing the check under pipefail. platform 2 is iOS, 1 is macOS.
  plat=$( (otool -l "$PREFIX/lib/libLLVMCore.a" 2>/dev/null || true) | grep -m1 'platform' || true )
  case "$plat" in
    *"platform 2"*) : ;;
    *) die "libLLVMCore.a is not an iOS binary ($plat)" ;;
  esac
  log "libLLVMCore.a: iOS arm64 ($(ls "$PREFIX/lib"/*.a | wc -l | tr -d ' ') libraries)"
fi
log "installed -> $PREFIX ($(du -sh "$PREFIX" | cut -f1))"
log "LLVM15 ($TARGET) OK"

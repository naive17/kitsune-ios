#!/usr/bin/env bash
# Wine for macOS arm64 in build/wine-macos: the arm64ec/aarch64 PE modules the
# app ships (they do not depend on the host OS) and the host tools (widl,
# winebuild) the other builds use. Requires 01-toolchain.sh and 02-fetch.sh.
# i386 is not built: 32-bit programs would also need FEX's WoW64 module.
source "$(dirname "$0")/common.sh"

WINE_SRC="$THIRD_PARTY/wine"
B="$BUILD/wine-macos"
[ -d "$WINE_SRC" ] || die "run 02-fetch.sh first"

command -v aarch64-w64-mingw32-clang >/dev/null || die "llvm-mingw not on PATH; run 01-toolchain.sh"
log "PE cross-compiler: $(aarch64-w64-mingw32-clang --version | head -1)"
log "bison: $(bison --version | head -1)"

# The PE modules keep the TEB in x28 like the unix side, and WINE_IOS_JIT_ARENA
# selects their iOS code paths, such as moving USER_SHARED_DATA off 0x7ffe0000,
# which iOS leaves unmapped. These go in the per-arch CFLAGS because CROSSCFLAGS
# also reaches the x86_64 cross compiler ARM64EC needs, and -ffixed-x28 makes
# configure reject that compiler.
ARCH_CFLAGS="-g -O2 -ffixed-x28 -DWINE_TEB_IN_X28 -DWINE_IOS_JIT_ARENA"

# configure bakes the per-arch CFLAGS into the Makefile, so a change to
# ARCH_CFLAGS needs a fresh build dir.
STAMP="$B/.archcflags.stamp"
if [ -f "$B/Makefile" ] && [ "$(cat "$STAMP" 2>/dev/null)" != "$ARCH_CFLAGS" ]; then
  warn "ARCH_CFLAGS changed since configure; rebuilding build/wine-macos from scratch"
  rm -rf "$B"
fi

mkdir -p "$B"
if [ ! -f "$B/Makefile" ]; then
  log "configuring wine (arm64ec,aarch64)"
  log "  aarch64_CFLAGS=$ARCH_CFLAGS"
  ( cd "$B" && "$WINE_SRC/configure" \
      --disable-tests \
      --with-mingw=clang \
      --enable-archs=arm64ec,aarch64 \
      --without-x \
      aarch64_CFLAGS="$ARCH_CFLAGS" \
      arm64ec_CFLAGS="$ARCH_CFLAGS" \
  ) > "$BUILD/wine-configure.log" 2>&1 \
    || { tail -30 "$BUILD/wine-configure.log"; die "configure failed (see $BUILD/wine-configure.log)"; }
fi

printf '%s' "$ARCH_CFLAGS" > "$B/.archcflags.stamp"
log "building wine -j$NPROC"
make -C "$B" -j"$NPROC"
log "wine-macos build finished"

#!/usr/bin/env bash
# GnuTLS for iOS as one dylib, with GMP, nettle and hogweed linked in statically:
# out/gnutls-ios/{include,lib/libgnutls.30.dylib}. Downloads the pinned tarballs.
#
# schannel and crypt32 dlopen it as @loader_path/libgnutls.30.dylib (set by
# 11-wine-ios.sh), so it ships beside their unix halves in lib/wine/aarch64-unix.
# Everything is built with -ffixed-x28 and without hand-written assembly: the
# TEB lives in x28, and a signal landing in code that uses x28 as scratch would
# read a garbage TEB.
source "$(dirname "$0")/common.sh"

B="$BUILD/gnutls-ios"
STAGE="$B/prefix"
DEST="$OUT/gnutls-ios"
SRC="$B/src"
mkdir -p "$SRC" "$STAGE"

fetch() {  # url sha256
  local url="$1" sha="$2" f="$SRC/$(basename "$1")"
  if [ ! -f "$f" ] || [ "$(shasum -a 256 "$f" | cut -d' ' -f1)" != "$sha" ]; then
    log "downloading $(basename "$f")"
    curl -fL --retry 3 --connect-timeout 20 -o "$f.part" "$url" || die "download failed: $url"
    mv "$f.part" "$f"
  fi
  [ "$(shasum -a 256 "$f" | cut -d' ' -f1)" = "$sha" ] || die "$(basename "$f"): SHA-256 mismatch"
}

fetch "$GMP_URL" "$GMP_SHA256"
fetch "$NETTLE_URL" "$NETTLE_SHA256"
fetch "$GNUTLS_URL" "$GNUTLS_SHA256"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)" || die "no iPhoneOS SDK"
FLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=15.0 -ffixed-x28"
export CC="$(xcrun --sdk iphoneos -f clang) $FLAGS"
export CXX="$(xcrun --sdk iphoneos -f clang++) $FLAGS"
export CFLAGS="-O2 -fPIC"
export AR="$(xcrun --sdk iphoneos -f ar)"
export RANLIB="$(xcrun --sdk iphoneos -f ranlib)"
export CC_FOR_BUILD="$(xcrun --sdk macosx -f clang) -isysroot $(xcrun --sdk macosx --show-sdk-path)"
export PKG_CONFIG_LIBDIR="$STAGE/lib/pkgconfig"
export PKG_CONFIG_PATH="$STAGE/lib/pkgconfig"
HOST=aarch64-apple-darwin

stage() {  # name tarball dir configure-args...
  local name="$1" tarball="$2" dir="$3"; shift 3
  [ -f "$B/$name.done" ] && { log "$name already built"; return 0; }
  rm -rf "$B/$dir"
  tar -C "$B" -xf "$SRC/$tarball"
  log "configuring $name"
  ( cd "$B/$dir" && ./configure --host=$HOST --prefix="$STAGE" "$@" ) > "$B/$name-configure.log" 2>&1 \
    || { tail -25 "$B/$name-configure.log"; die "$name configure failed"; }
  log "building $name"
  make -C "$B/$dir" -j"$NPROC" > "$B/$name-make.log" 2>&1 \
    || { grep -m5 -B2 -A8 "error:" "$B/$name-make.log"; die "$name build failed"; }
  make -C "$B/$dir" install >> "$B/$name-make.log" 2>&1 || die "$name install failed"
  touch "$B/$name.done"
}

stage gmp "gmp-$GMP_VER.tar.xz" "gmp-$GMP_VER" \
  --enable-static --disable-shared --disable-assembly --with-pic

stage nettle "nettle-$NETTLE_VER.tar.gz" "nettle-$NETTLE_VER" \
  --enable-static --disable-shared --disable-assembler --disable-documentation \
  --disable-openssl --enable-pic \
  --with-include-path="$STAGE/include" --with-lib-path="$STAGE/lib"

stage gnutls "gnutls-$GNUTLS_VER.tar.xz" "gnutls-$GNUTLS_VER" \
  --enable-shared --disable-static \
  --disable-hardware-acceleration \
  --with-included-libtasn1 --with-included-unistring \
  --without-p11-kit --without-tpm --without-tpm2 --without-idn \
  --without-brotli --without-zstd --without-zlib \
  --disable-doc --disable-tests --disable-tools --disable-cxx \
  --disable-libdane --disable-nls --disable-guile \
  --with-default-trust-store-file= --with-default-trust-store-dir= \
  NETTLE_CFLAGS="-I$STAGE/include" NETTLE_LIBS="-L$STAGE/lib -lnettle" \
  HOGWEED_CFLAGS="-I$STAGE/include" HOGWEED_LIBS="-L$STAGE/lib -lhogweed -lgmp" \
  GMP_CFLAGS="-I$STAGE/include" GMP_LIBS="-L$STAGE/lib -lgmp"

rm -rf "$DEST"
mkdir -p "$DEST/lib"
cp -R "$STAGE/include" "$DEST/include"
cp "$STAGE/lib/libgnutls.30.dylib" "$DEST/lib/"
DYLIB="$DEST/lib/libgnutls.30.dylib"
install_name_tool -id "@loader_path/libgnutls.30.dylib" "$DYLIB"
ln -sf libgnutls.30.dylib "$DEST/lib/libgnutls.dylib"

plat=$(xcrun vtool -show-build-version "$DYLIB" 2>/dev/null | awk '/platform/{print $2}')
[ "$plat" = "IOS" ] || die "libgnutls is platform=$plat, expected IOS"
deps=$(otool -L "$DYLIB" | tail -n +2 | awk '{print $1}' \
  | grep -v -E '^(@loader_path/libgnutls\.30\.dylib|/usr/lib/libSystem|/usr/lib/libiconv|/System/Library/Frameworks/(Security|CoreFoundation)\.framework)' || true)
missing=$(nm -u "$DYLIB" | grep -E '^_(Sec|kSec|CF|kCF)' || true)
[ -z "$missing" ] || die "libgnutls imports Security/CoreFoundation symbols; check they exist on iOS: $missing"
[ -z "$deps" ] || die "libgnutls links unexpected libraries: $deps"
exports=$(nm -gU "$DYLIB")
for sym in _gnutls_global_init _gnutls_cipher_init _gnutls_handshake; do
  grep -q " T $sym$" <<< "$exports" || die "libgnutls does not export $sym"
done
log "gnutls staged: $DYLIB ($(du -h "$DYLIB" | cut -f1))"

#!/usr/bin/env bash
# Wine's unix side for arm64-apple-ios: every unix half that builds for iOS,
# into out/ios-unix, and wineserver as build/wine-ios/libwineserver.a for the
# app to link. Configures on the first run or with --reconfigure; later runs
# are incremental.
#
# Needs the native tools from 07-wine-macos.sh, FreeType (04-freetype.sh) and
# GnuTLS (05-gnutls-ios.sh).
source "$(dirname "$0")/common.sh"

WINE_SRC="$THIRD_PARTY/wine"
HOST_TOOLS="$BUILD/wine-macos"
B="$BUILD/wine-ios"
[ -d "$WINE_SRC" ] || die "run 02-fetch.sh first"
[ -x "$HOST_TOOLS/tools/widl/widl" ] || die "run 07-wine-macos.sh first (need native tools)"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)" || die "no iPhoneOS SDK"
IOS_MIN=15.0

# make re-runs configure when configure.ac changes; that needs the PE cross
# compiler and bison 3 on PATH and the cache seeds below in the environment.
export PATH="$MINGW_BIN:/opt/homebrew/opt/bison/bin:/opt/homebrew/bin:$PATH"

export CC="$(xcrun --sdk iphoneos -f clang)"
export CXX="$(xcrun --sdk iphoneos -f clang++)"
export AR="$(xcrun --sdk iphoneos -f ar)"
export RANLIB="$(xcrun --sdk iphoneos -f ranlib)"
# WINE_IOS_JIT_ARENA: PE code runs from the debugger-blessed arena, since iOS
# refuses to make pages executable with mprotect (src/ios/jit_arena.c).
# WINE_TEB_IN_X28 and -ffixed-x28: Darwin zeroes x18 on preemption, so the TEB
# lives in x28, and every translation unit must keep x28 reserved.
export CFLAGS="-target arm64-apple-ios$IOS_MIN -isysroot $SDK -fno-common -DWINE_IOS_JIT_ARENA -ffixed-x28 -DWINE_TEB_IN_X28"
export LDFLAGS="-target arm64-apple-ios$IOS_MIN -isysroot $SDK"
export CPPFLAGS="$CFLAGS"

# FreeType is linked statically; the soname seed only has to be defined for the
# font code to compile in.
FT_IOS="$OUT/freetype-ios"
[ -f "$FT_IOS/lib/libfreetype.a" ] || die "no freetype for ios; run 04-freetype.sh"
export FREETYPE_CFLAGS="-I$FT_IOS/include/freetype2"
export FREETYPE_LIBS="$FT_IOS/lib/libfreetype.a"
export ac_cv_lib_soname_freetype="libfreetype.6.dylib"
export ac_cv_header_ft2build_h=yes

# schannel and crypt32 load GnuTLS from their own directory.
GT_IOS="$OUT/gnutls-ios"
[ -f "$GT_IOS/lib/libgnutls.30.dylib" ] || die "no gnutls for ios; run 05-gnutls-ios.sh"
export GNUTLS_CFLAGS="-I$GT_IOS/include"
export GNUTLS_LIBS="-L$GT_IOS/lib -lgnutls"
export ac_cv_lib_soname_gnutls="@loader_path/libgnutls.30.dylib"
export ac_cv_func_gnutls_cipher_init=yes

# Xcode 27's SDKs declare pipe2 as macOS/iOS 27 only, but configure's link
# test passes against them, so HAVE_PIPE2 gets set and the call is weak-linked.
# On an older OS it binds to NULL and server_pipe() jumps to address 0 at boot.
# Every pipe2 call in Wine has a pipe()+fcntl fallback under !HAVE_PIPE2.
export ac_cv_func_pipe2=no

mkdir -p "$B"
# A build dir configured before the seed above has HAVE_PIPE2 baked in.
STALE_PIPE2=0
grep -qs '^#define HAVE_PIPE2 1' "$B/include/config.h" && STALE_PIPE2=1
if [ ! -f "$B/Makefile" ] || [ "${1:-}" = --reconfigure ] || [ "$STALE_PIPE2" = 1 ]; then
  log "configuring wine for arm64-apple-ios"
  # arm64ec: signal_arm64ec.c, the exception path between x86 and EC code, is
  # compiled only for that architecture.
  ( cd "$B" && "$WINE_SRC/configure" \
      --host=aarch64-apple-darwin \
      --with-wine-tools="$HOST_TOOLS" \
      --disable-tests \
      --without-x \
      --with-freetype \
      --with-gnutls \
      --without-fontconfig \
      --enable-archs=aarch64,arm64ec \
  ) > "$BUILD/wine-ios-configure.log" 2>&1 || {
    grep -nE "^configure: error|error:|cannot find|not found" "$BUILD/wine-ios-configure.log" \
      | grep -viE "checking|guessing" | head -20 || true
    die "configure failed; see $BUILD/wine-ios-configure.log"
  }
fi

# configure cannot tell iOS from macOS and links AudioUnit, which has no binary
# on iOS; its symbols are in AudioToolbox. Bring the Makefile up to date first:
# after a checkout touched configure.ac or a Makefile.in, make regenerated it
# halfway through the build, put AudioUnit back and failed to link winecoreaudio.
make -C "$B" Makefile >/dev/null || die "regenerating $B/Makefile failed"
if grep -q -- '-framework AudioUnit ' "$B/Makefile"; then
  sed -i '' 's/-framework AudioUnit //g' "$B/Makefile"
fi

# A DLL whose unix half is missing fails its DllMain with an error that names
# the PE module, so every half is attempted and the ones that do not build for
# iOS are reported. The server's objects become libwineserver.a; its main() is
# compiled out for the in-process build.
so_targets=$(grep -oE '^dlls/[a-z0-9_.]+/[a-z0-9_]+\.so' "$B/Makefile" | sort -u | tr '\n' ' ')
srv_objs=$(cd "$WINE_SRC/server" && ls *.c | sed 's|^|server/|; s|\.c$|.o|' | tr '\n' ' ')
mandatory="dlls/ntdll/ntdll.so dlls/win32u/win32u.so dlls/crypt32/crypt32.so dlls/secur32/secur32.so dlls/wineios.drv/wineios.so dlls/winecoreaudio.drv/winecoreaudio.so"
log "building the iOS unix side"
make -C "$B" -j"$NPROC" $mandatory $srv_objs || die "a mandatory unix half or the server failed to build"
built="$mandatory"
skipped=""
for t in $so_targets; do
  case " $mandatory " in *" $t "*) continue;; esac
  if make -C "$B" -j"$NPROC" "$t" >/dev/null 2>&1; then built="$built $t"
  else skipped="$skipped $(basename "$t")"; fi
done
[ -z "$skipped" ] || warn "unix halves that do not build for iOS:$skipped"

# Exactly the objects of server/*.c, not whatever else sits in the directory.
rm -f "$B/libwineserver.a"
objs=""
for o in $srv_objs; do objs="$objs $B/$o"; done
ar rcs "$B/libwineserver.a" $objs || die "ar failed"
ar t "$B/libwineserver.a" | grep -q ios_inproc.o || die "ios_inproc.o missing from archive"
log "  libwineserver.a  $(du -h "$B/libwineserver.a" | cut -f1)"

mkdir -p "$OUT/ios-unix"
for t in $built; do
  plat=$(xcrun vtool -show-build-version "$B/$t" 2>/dev/null | awk '/platform/{print $2}')
  [ "$plat" = "IOS" ] || die "$t is platform=$plat, expected IOS"
  cp "$B/$t" "$OUT/ios-unix/"
done
# nsi.dll calls nsiproxy's unix half directly; iOS has no \\.\Nsi device.
if [ -f "$B/dlls/nsiproxy.sys/nsiproxy.so" ]; then
  cp "$B/dlls/nsiproxy.sys/nsiproxy.so" "$OUT/ios-unix/nsi.so"
fi
cp "$GT_IOS/lib/libgnutls.30.dylib" "$OUT/ios-unix/"
log "iOS unix side staged in $OUT/ios-unix: $(echo $built | wc -w | tr -d ' ') halves"

#!/usr/bin/env bash
# Build the macOS host harness (build/kitsune-host), which boots the iOS-shaped
# Wine in one process as the app does, and the tree it runs (build/host-tree).
# Requires out/wine-tree (13-stage-wine-tree.sh) and 04-freetype.sh's output.
source "$(dirname "$0")/common.sh"

# A separate build dir: the iOS cross-build depends on build/wine-macos, which
# must not be reconfigured with these flags.
B="$BUILD/wine-host"
TREE="$BUILD/host-tree"
PE_SRC="$ROOT/out/wine-tree"
HARNESS="$BUILD/kitsune-host"

export PATH="$MINGW_BIN:/opt/homebrew/opt/bison/bin:/opt/homebrew/bin:$PATH"

# Same macros as the device build; without them the port's code is compiled out.
# Darwin zeroes x18 on preemption, so the TEB lives in x28 (WINE_TEB_IN_X28) and
# every translation unit must reserve it with -ffixed-x28. See include/winnt.h.
export CFLAGS="-g -O1 -fno-common -DWINE_IOS_JIT_ARENA -ffixed-x28 -DWINE_TEB_IN_X28"
# Homebrew's lib dir is not on clang's default search path; without it a
# reconfigure fails configure's -lfreetype check.
export LDFLAGS="$(command -v brew >/dev/null && echo "-L$(brew --prefix)/lib")"
export CPPFLAGS="$CFLAGS"

# FreeType is the static archive from 04-freetype.sh; the seeded cache variables
# stand in for WINE_CHECK_SONAME's shared-library probe (freetype.c binds
# directly under WINE_IOS_JIT_ARENA). Exported here, not in the configure block,
# because make can rerun `config.status --recheck` on its own.
FT_MACOS="$OUT/freetype-macos"
[ -f "$FT_MACOS/lib/libfreetype.a" ] || die "no freetype for macos; run 04-freetype.sh"
export FREETYPE_CFLAGS="-I$FT_MACOS/include/freetype2"
export FREETYPE_LIBS="$FT_MACOS/lib/libfreetype.a"
export ac_cv_lib_soname_freetype="libfreetype.6.dylib"
export ac_cv_header_ft2build_h=yes

# Xcode 27's SDKs declare pipe2 as macOS/iOS 27 only, but configure's link
# test passes against them, so HAVE_PIPE2 gets set and the call is weak-linked.
# On an older OS it binds to NULL and server_pipe() jumps to address 0 at boot.
# Every pipe2 call in Wine has a pipe()+fcntl fallback under !HAVE_PIPE2.
export ac_cv_func_pipe2=no

# configure bakes CFLAGS into the Makefile, so a CFLAGS change needs a fresh
# configure; otherwise a new -D is silently ignored.
STAMP="$B/.cflags.stamp"
if [ -f "$B/Makefile" ] && [ "$(cat "$STAMP" 2>/dev/null)" != "$CFLAGS" ]; then
  warn "CFLAGS changed since configure; reconfiguring build/wine-host"
  rm -rf "$B"
fi
if grep -qs '^#define HAVE_PIPE2 1' "$B/include/config.h"; then
  warn "build/wine-host was configured with HAVE_PIPE2; reconfiguring"
  rm -rf "$B"
fi

if [ ! -f "$B/Makefile" ]; then
  log "configuring wine for the macOS host (build/wine-host)"
  mkdir -p "$B"
  # arm64ec is required: dlls/ntdll/signal_arm64ec.c, the x86<->EC exception
  # path, is empty without __arm64ec__, and the ARM64 dispatcher used instead
  # rejects frames on FEX's emulator stack. configure then adds x86_64 too.
  ( cd "$B" && "$THIRD_PARTY/wine/configure" \
      --disable-tests \
      --without-x \
      --with-freetype \
      --without-fontconfig \
      --enable-archs=aarch64,arm64ec \
  ) > "$BUILD/wine-host-configure.log" 2>&1 \
    || { warn "configure failed; first errors:";
         grep -nE "^configure: error|error:" "$BUILD/wine-host-configure.log" | head -10;
         die "see $BUILD/wine-host-configure.log"; }
fi
mkdir -p "$B"; printf '%s' "$CFLAGS" > "$B/.cflags.stamp"

log "building host unix core"
# Only the server's objects are built: with main() compiled out for the
# in-process build, server/wineserver cannot link.
SRV_OBJS=$(cd "$THIRD_PARTY/wine/server" && ls *.c | sed 's|^|server/|; s|\.c$|.o|' | tr '\n' ' ')
# Every unix half: a missing one fails its DLL's DllMain with an error naming
# the PE module, not the .so. The '.' in the pattern matches the *.drv dirs.
SO_TARGETS=$(grep -oE '^dlls/[a-z0-9_.]+/[a-z0-9_]+\.so' "$B/Makefile" | sort -u | tr '\n' ' ')
make -C "$B" -j"$NPROC" $SO_TARGETS $SRV_OBJS \
  || die "host core build failed"

# wineserver as a library, as on iOS; ios_inproc.o supplies the thread entry.
log "packing libwineserver.a"
OBJS=$(ls "$B"/server/*.o)   # main.o included: its main() is compiled out
rm -f "$B/libwineserver.a"
ar rcs "$B/libwineserver.a" $OBJS || die "ar failed"
ar t "$B/libwineserver.a" | grep -q ios_inproc.o || die "ios_inproc.o missing from archive"

log "building harness"
# common.sh points DEVELOPER_DIR at Xcode, so a bare clang has no macOS sysroot.
MACSDK="$(xcrun --sdk macosx --show-sdk-path)"
# host_surface.m provides the driver's device-side host hooks and an offscreen
# compositor (dormant unless KITSUNE_HOST_SURFACE=1); -Wl,-export_dynamic, also
# needed by the wineserver objects, lets dlsym(RTLD_DEFAULT) find the hooks.
xcrun --sdk macosx clang -isysroot "$MACSDK" -g -O1 -Wall -Wextra \
  -I"$ROOT/src/ios" -I"$ROOT/src/host" \
  "$ROOT/src/host/host_main.c" "$ROOT/src/host/host_arena.c" \
  "$ROOT/src/host/host_surface.m" \
  -Wl,-all_load "$B/libwineserver.a" \
  -Wl,-export_dynamic \
  -framework CoreFoundation -framework Foundation \
  -framework QuartzCore -framework Metal \
  -o "$HARNESS" \
  || die "harness link failed"

# PE modules from the cross build (host-independent), unix halves from here.
log "staging host tree"
rm -rf "$TREE"
mkdir -p "$TREE/lib/wine/aarch64-windows" "$TREE/lib/wine/aarch64-unix" "$TREE/share/wine/nls"
[ -d "$PE_SRC/lib/wine/aarch64-windows" ] || die "no PE modules at $PE_SRC; run 13-stage-wine-tree.sh"
cp "$PE_SRC/lib/wine/aarch64-windows/"* "$TREE/lib/wine/aarch64-windows/"
for so in $SO_TARGETS; do cp "$B/$so" "$TREE/lib/wine/aarch64-unix/" 2>/dev/null || true; done
log "unix halves: $(ls "$TREE/lib/wine/aarch64-unix" | wc -l | tr -d ' ')"
cp -L "$THIRD_PARTY/wine/nls/"*.nls "$TREE/share/wine/nls/" 2>/dev/null || true
# wine.inf drives prefix population; without it wineboot --init leaves the
# prefix empty. The build generates it into loader/, not the source tree.
for inf in wine.inf; do
  src=$(find "$BUILD/wine-host" "$BUILD/wine-macos" -name "$inf" -not -path "*/tests/*" 2>/dev/null | head -1)
  [ -n "$src" ] && cp "$src" "$TREE/share/wine/" || warn "$inf not found"
done
[ -f "$TREE/share/wine/nls/l_intl.nls" ] || warn "l_intl.nls missing"

# configure skips the fonts subdir without fontforge, but Wine's source tree
# carries the built .ttf files; without them windows draw no text.
mkdir -p "$TREE/share/wine/fonts"
cp "$THIRD_PARTY/wine/fonts/"*.ttf "$TREE/share/wine/fonts/" 2>/dev/null || true
log "fonts: $(ls "$TREE/share/wine/fonts"/*.ttf 2>/dev/null | wc -l | tr -d ' ') prebuilt ttf"

cat <<EOF

  built: $HARNESS
  tree : $TREE

  run:
    KITSUNE_TREE=$TREE $HARNESS \\
        $TREE/lib/wine/aarch64-windows/wineboot.exe --init

  A pass here means the LOGIC is right. It does not mean iOS will allow it:
  macOS permits mprotect(PROT_EXEC), permits remapping over the arena, and lets
  protection changes go both ways. See src/host/host_arena.c.
EOF

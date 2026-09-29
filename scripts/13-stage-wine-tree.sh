#!/usr/bin/env bash
# Assemble out/wine-tree, the full Wine tree: the iOS unix halves, the PE
# modules and programs, nls, wine.inf, fonts, and the FEX and D3D overlay from
# 12-stage-prefix.sh. Requires 11-wine-ios.sh and 07-wine-macos.sh; the PE
# modules do not depend on the host OS, so they come from the macOS build.
# STRIP_PE=0 keeps their debug info.
#
# The layout is fixed: ntdll.so finds everything relative to its own path
# (init_paths() in dlls/ntdll/unix/loader.c). The PE modules are ARM64X images,
# ARM64 and ARM64EC code in one file, so all of them go in aarch64-windows.
source "$(dirname "$0")/common.sh"

IOS_BUILD="$BUILD/wine-ios"
MAC_BUILD="$BUILD/wine-macos"
TREE="$OUT/wine-tree"

[ -f "$IOS_BUILD/dlls/ntdll/ntdll.so" ] || die "run 11-wine-ios.sh first"
[ -d "$MAC_BUILD/dlls" ] || die "run 07-wine-macos.sh first (PE modules)"

rm -rf "$TREE"
mkdir -p "$TREE/lib/wine/aarch64-unix" "$TREE/lib/wine/aarch64-windows" \
         "$TREE/share/wine"

unix_count=0
while read -r so; do
  plat=$(xcrun vtool -show-build-version "$so" 2>/dev/null | awk '/platform/{print $2}')
  [ "$plat" = "IOS" ] || die "$so is platform=$plat, expected IOS"
  cp "$so" "$TREE/lib/wine/aarch64-unix/"
  unix_count=$((unix_count+1))
done < <(find "$IOS_BUILD/dlls" -maxdepth 2 -name '*.so')
log "unix halves (iOS): $unix_count"

pe_a=0
while read -r m; do cp "$m" "$TREE/lib/wine/aarch64-windows/"; pe_a=$((pe_a+1)); done \
  < <(find "$MAC_BUILD/dlls" -path '*/aarch64-windows/*' -type f \
        \( -name '*.dll' -o -name '*.drv' -o -name '*.exe' -o -name '*.sys' -o -name '*.acm' -o -name '*.ocx' \))
log "PE modules: $pe_a (ARM64X hybrids in aarch64-windows)"

prog=0
while read -r exe; do cp "$exe" "$TREE/lib/wine/aarch64-windows/"; prog=$((prog+1)); done \
  < <(find "$MAC_BUILD/programs" -path '*/aarch64-windows/*.exe' 2>/dev/null)
log "programs: $prog"

# From the source tree, dereferenced: the build dir's nls files are symlinks to
# absolute host paths.
mkdir -p "$TREE/share/wine/nls"
cp -L "$THIRD_PARTY"/wine/nls/*.nls "$TREE/share/wine/nls/" 2>/dev/null || true
# wineboot populates the prefix from wine.inf, which the build generates; the
# source tree does not have it.
src=$(find "$MAC_BUILD" -name wine.inf -not -path "*/tests/*" 2>/dev/null | head -1)
[ -n "$src" ] && cp "$src" "$TREE/share/wine/" || warn "wine.inf not found; the prefix cannot be populated"

[ -f "$TREE/share/wine/nls/l_intl.nls" ] || die "l_intl.nls missing; wineserver will abort at boot"
log "nls: $(ls "$TREE/share/wine/nls" | wc -l | tr -d ' ') files (dereferenced)"

# Without fontforge the build skips fonts/, so the prebuilt .ttf files come from
# the source tree. win32u loads them from <datadir>/fonts, here share/wine/fonts.
mkdir -p "$TREE/share/wine/fonts"
cp "$THIRD_PARTY"/wine/fonts/*.ttf "$TREE/share/wine/fonts/" 2>/dev/null || true
n_fonts=$(ls "$TREE/share/wine/fonts"/*.ttf 2>/dev/null | wc -l | tr -d ' ')
[ "$n_fonts" -gt 0 ] || die "no fonts staged; GUI programs will render no text"
log "fonts: $n_fonts prebuilt ttf"

# FEX and the D3D modules from 12-stage-prefix.sh, copied after Wine's own
# modules so that they replace Wine's D3D DLLs.
if [ -d "$OUT/prefix/aarch64-windows" ]; then
  cp "$OUT/prefix/aarch64-windows/"*.dll "$TREE/lib/wine/aarch64-windows/" 2>/dev/null || true
  log "overlaid FEX + D3D stack from out/prefix"
fi

if [ "${STRIP_PE:-1}" = "1" ]; then
  before=$(du -sm "$TREE" | cut -f1)
  find "$TREE/lib/wine/aarch64-windows" -name '*.dll' -o -name '*.exe' \
    | while read -r f; do "$MINGW_BIN/llvm-strip" --strip-debug "$f" 2>/dev/null || true; done
  log "stripped debug info: ${before}MB -> $(du -sm "$TREE" | cut -f1)MB"
fi

log "tree staged: $TREE ($(du -sh "$TREE" | cut -f1))"
find "$TREE" -maxdepth 3 -type d | sed "s|$TREE|  .|"

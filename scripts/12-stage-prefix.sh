#!/usr/bin/env bash
# Stage the FEX and D3D PE modules into out/prefix/aarch64-windows, which
# 13-stage-wine-tree.sh overlays on the Wine tree; PROVENANCE.txt records where
# each DLL came from. Requires 06-fex-arm64ec.sh, 08-dxvk.sh, 09-vkd3d.sh and,
# for the default provider, 10-dxmt.sh.
#
# Usage: [D3D11_PROVIDER=dxmt|dxvk] scripts/12-stage-prefix.sh
#
# DXMT and DXVK both provide d3d11, d3d10core and dxgi, so exactly one is taken.
# DXMT is the default: it translates D3D11 to Metal directly, without Vulkan.
source "$(dirname "$0")/common.sh"

ARCH="${ARCH:-arm64ec}"
D3D11_PROVIDER="${D3D11_PROVIDER:-dxmt}"
STAGE="$OUT/prefix/aarch64-windows"
rm -rf "$STAGE"; mkdir -p "$STAGE"

take() { # take <src-dir> <dll-basename> <provider-label>
  local src="$1/$2.dll" name="$2" prov="$3"
  [ -f "$src" ] || { warn "missing $name.dll from $prov ($src)"; return 1; }
  cp "$src" "$STAGE/$name.dll"
  printf '%-16s <- %s\n' "$name.dll" "$prov" >> "$STAGE/PROVENANCE.txt"
  log "  $name.dll <- $prov"
}

log "composing prefix (d3d11 provider: $D3D11_PROVIDER)"

case "$D3D11_PROVIDER" in
  dxmt)
    take "$OUT/dxmt-arm64ec" d3d11     "dxmt"
    take "$OUT/dxmt-arm64ec" d3d10core "dxmt"
    take "$OUT/dxmt-arm64ec" dxgi      "dxmt"
    take "$OUT/dxmt-arm64ec" winemetal "dxmt"
    ;;
  dxvk)
    take "$OUT/dxvk-$ARCH" d3d11     "dxvk"
    take "$OUT/dxvk-$ARCH" d3d10core "dxvk"
    take "$OUT/dxvk-$ARCH" dxgi      "dxvk"
    ;;
  *) die "D3D11_PROVIDER must be dxmt or dxvk" ;;
esac

take "$OUT/dxvk-$ARCH"  d3d9      "dxvk"
take "$OUT/vkd3d-$ARCH" d3d12     "vkd3d-proton"
take "$OUT/vkd3d-$ARCH" d3d12core "vkd3d-proton"
take "$OUT/fex" libarm64ecfex     "FEX"

# ntdll's load_arm64ec_module() loads the emulator as xtajit64.dll, so FEX is
# staged under that name too. The registry override it honours
# (HKLM\Software\Microsoft\Wow64\amd64) is not used: it would live in the user's
# prefix, which persists across builds.
if [ -f "$STAGE/libarm64ecfex.dll" ]; then
  cp "$STAGE/libarm64ecfex.dll" "$STAGE/xtajit64.dll"
  printf '%-16s <- %s\n' "xtajit64.dll" "FEX (copy of libarm64ecfex.dll)" >> "$STAGE/PROVENANCE.txt"
  log "  xtajit64.dll <- FEX (copy; the name ntdll hardcodes)"
fi

echo
log "staged -> $STAGE"
cat "$STAGE/PROVENANCE.txt"

# Every DLL must be ARM64EC: x86-64 code cannot call into a plain ARM64 image.
bad=0
for f in "$STAGE"/*.dll; do
  m="$("$MINGW_BIN/llvm-readobj" --file-headers "$f" | awk '/Machine:/{print $NF}')"
  [ "$m" = "(0xA641)" ] || { warn "$(basename "$f") is $m, expected ARM64EC"; bad=1; }
done
[ "$bad" -eq 0 ] || die "non-ARM64EC images staged"
log "all staged DLLs verified ARM64EC"

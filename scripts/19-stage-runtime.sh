#!/usr/bin/env bash
# Assemble the runtime bundled by thin app builds (.deploy/runtime) from
# out/ios-unix, out/wine-tree and out/dxmt-arm64ec.
set -euo pipefail
cd "$(dirname "$0")/.."
RT=.deploy/runtime
PE=out/wine-tree/lib/wine/aarch64-windows
SHARE=out/wine-tree/share/wine
test -f out/ios-unix/winecoreaudio.so || { echo "out/ios-unix incomplete; run 11-wine-ios.sh and 15-dxmt-ios.sh" >&2; exit 1; }
test -f out/ios-unix/winemetal.so || { echo "out/ios-unix/winemetal.so missing; run 15-dxmt-ios.sh" >&2; exit 1; }
test -f "$PE/ntdll.dll" || { echo "$PE incomplete; run 13-stage-wine-tree.sh" >&2; exit 1; }
test -d "$SHARE/fonts" || { echo "$SHARE/fonts missing; run 13-stage-wine-tree.sh" >&2; exit 1; }
test -f out/dxmt-arm64ec/d3d11.dll || { echo "out/dxmt-arm64ec missing; run 10-dxmt.sh" >&2; exit 1; }

rm -rf "$RT"
mkdir -p "$RT/lib/wine/aarch64-unix" "$RT/lib/wine/aarch64-windows" "$RT/share/wine"
cp out/ios-unix/*.so out/ios-unix/libgnutls.30.dylib "$RT/lib/wine/aarch64-unix/"
# The display driver's PE half pairs with wineios.so, so it ships beside it.
cp "$PE/ntdll.dll" "$PE/apisetschema.dll" "$PE/wineios.drv" "$RT/lib/wine/aarch64-windows/"
bash scripts/build-session-host.sh "$RT/lib/wine/aarch64-windows"
cp out/dxmt-arm64ec/d3d11.dll out/dxmt-arm64ec/dxgi.dll out/dxmt-arm64ec/d3d10core.dll out/dxmt-arm64ec/winemetal.dll \
   "$RT/lib/wine/aarch64-windows/"
bash scripts/stage-xinput.sh "$RT/lib/wine" "$PE" >/dev/null
cp -R "$SHARE/nls" "$SHARE/fonts" "$RT/share/wine/"
cp "$SHARE/wine.inf" "$RT/share/wine/"
for dll in "$RT"/lib/wine/aarch64-windows/{d3d11,dxgi,d3d10core,winemetal}.dll; do
  n=$(grep -c "Wine builtin DLL" "$dll" || true)
  [ "$n" -ge 1 ] || { echo "$dll is not stamped as a Wine builtin (scripts/stamp-builtin.py)" >&2; exit 1; }
done
echo "runtime staged in $RT: $(ls "$RT/lib/wine/aarch64-unix" | wc -l | tr -d ' ') unix halves, $(ls "$RT/lib/wine/aarch64-windows" | wc -l | tr -d ' ') PE modules"

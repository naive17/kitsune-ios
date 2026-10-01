#!/bin/bash
# Copy the ARM64X XInput DLLs and sechost (hotplug notifications) into both
# builtin dirs: native x64 DLLs load from x86_64-windows even under ARM64EC.
# Usage: bash scripts/lib/stage-xinput.sh APP/lib/wine [SOURCE/aarch64-windows]
set -euo pipefail
dest=${1:?expected destination lib/wine directory}
src=${2:-$dest/aarch64-windows}
variants=(xinput1_1 xinput1_2 xinput1_3 xinput1_4 xinput9_1_0 xinputuap)
modules=("${variants[@]}" sechost)

# Check the whole set first: builtin XInput is forced, so none may be missing.
for variant in "${modules[@]}"; do
  test -s "$src/$variant.dll" || { echo "Missing XInput build: $src/$variant.dll" >&2; exit 1; }
done
mkdir -p "$dest/aarch64-windows" "$dest/x86_64-windows"
for variant in "${modules[@]}"; do
  for arch in aarch64-windows x86_64-windows; do
    target="$dest/$arch/$variant.dll"
    if ! cmp -s "$src/$variant.dll" "$target"; then
      cp "$src/$variant.dll" "$target"
    fi
  done
done
echo "XInput: six ARM64X builtins plus sechost notifications staged for native-x64 and ARM64EC lookup"

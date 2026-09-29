#!/usr/bin/env bash
# Records the Wine and DXMT working trees as the port's patches. New files in
# either tree are included.
source "$(dirname "$0")/common.sh"
for tree in wine dxmt; do
  git -C "$THIRD_PARTY/$tree" add -N .
done
git -C "$THIRD_PARTY/wine" diff HEAD > "$ROOT/patches/wine/ios-wine-working.patch"
git -C "$THIRD_PARTY/dxmt" diff HEAD > "$ROOT/patches/dxmt/ios-dxmt-full-vs-upstream.patch"
git -C "$ROOT" diff --stat -- patches/wine patches/dxmt

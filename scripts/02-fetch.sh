#!/usr/bin/env bash
# Shallow-clone the pinned upstreams at their exact SHAs and apply the Wine and
# DXMT ports. The Wine port is the patch series in patches/wine (README there).
source "$(dirname "$0")/common.sh"

require_disk_gb 8
mkdir -p "$THIRD_PARTY"

pin_clone "$WINE_URL"      "$WINE_SHA"      "$THIRD_PARTY/wine"
pin_clone "$FEX_URL"       "$FEX_SHA"       "$THIRD_PARTY/fex"
pin_clone "$DXVK_URL"      "$DXVK_SHA"      "$THIRD_PARTY/dxvk"
# apply-dxmt-port.sh commits a "Kitsune base" on top of DXMT's pin. A checkout
# from before the rename has an "ios-wine base" commit; apply-dxmt-port.sh
# explains how to redo it.
if [[ "$(git -C "$THIRD_PARTY/dxmt" log -1 --format=%s 2>/dev/null)" =~ ^(Kitsune|ios-wine)\ base$ ]] &&
   [ "$(git -C "$THIRD_PARTY/dxmt" rev-parse HEAD^)" = "$DXMT_SHA" ]; then
  log "dxmt already at $DXMT_SHA plus its Kitsune base commit"
else
  pin_clone "$DXMT_URL"    "$DXMT_SHA"      "$THIRD_PARTY/dxmt"
fi
pin_clone "$VKD3D_URL"     "$VKD3D_SHA"     "$THIRD_PARTY/vkd3d-proton"

apply_series "$THIRD_PARTY/wine" "$ROOT/patches/wine"
bash "$ROOT/scripts/apply-dxmt-port.sh"

log "fetched. disk free: $(df -g "$ROOT" | tail -1 | awk '{print $4}')GB"

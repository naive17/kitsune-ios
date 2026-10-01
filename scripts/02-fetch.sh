#!/usr/bin/env bash
# Shallow-clone the pinned upstreams at their exact SHAs and apply the Wine and
# DXMT ports, the patch series in patches/wine and patches/dxmt (README in each).
source "$(dirname "$0")/common.sh"

require_disk_gb 8
mkdir -p "$THIRD_PARTY"

pin_clone "$WINE_URL"      "$WINE_SHA"      "$THIRD_PARTY/wine"
pin_clone "$FEX_URL"       "$FEX_SHA"       "$THIRD_PARTY/fex"
pin_clone "$DXVK_URL"      "$DXVK_SHA"      "$THIRD_PARTY/dxvk"
[ -d "$THIRD_PARTY/dxmt/.git" ] && drop_legacy_base "$THIRD_PARTY/dxmt"
pin_clone "$DXMT_URL"      "$DXMT_SHA"      "$THIRD_PARTY/dxmt"
pin_clone "$VKD3D_URL"     "$VKD3D_SHA"     "$THIRD_PARTY/vkd3d-proton"

apply_series "$THIRD_PARTY/wine" "$ROOT/patches/wine"
apply_series "$THIRD_PARTY/dxmt" "$ROOT/patches/dxmt"

log "fetched. disk free: $(df -g "$ROOT" | tail -1 | awk '{print $4}')GB"

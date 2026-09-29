#!/usr/bin/env bash
# Copy files between this Mac and the app on the paired iPhone, over USB or
# Wi-Fi. UDID picks the phone and APP the app, as in the other device scripts.
#
#   scripts/device.sh logs [destination]
#   scripts/device.sh sync-tree [out/wine-core]
#   scripts/device.sh sync-fex [out/wine-core/lib/wine/aarch64-windows/libarm64ecfex.dll]
#
# sync-tree replaces Documents/wine, the tree a thin install runs; sync-fex
# replaces only the emulator in it. Relaunch the app afterwards.
source "$(dirname "$0")/common.sh"
cd "$ROOT"

APP="${APP:-$APP_ID}"
DEVICE_TIMEOUT=60
BULK_TIMEOUT=600
STATE="$ROOT/.deploy/device"

copy_from_app() {
  local udid="$1" bundle="$2" source="$3" destination="$4"
  xcrun devicectl device copy from --device "$udid" \
    --domain-type appDataContainer --domain-identifier "$bundle" \
    --source "$source" --destination "$destination" --quiet \
    --timeout "$DEVICE_TIMEOUT"
}

copy_to_app() {
  local udid="$1" bundle="$2" source="$3" destination="$4"
  xcrun devicectl device copy to --device "$udid" \
    --domain-type appDataContainer --domain-identifier "$bundle" \
    --source "$source" --destination "$destination" --quiet \
    --timeout "$DEVICE_TIMEOUT"
}

cmd_logs() {
  local udid destination name partial copied=0 failed=0
  udid="$(phone_udid)"
  destination="${1:-$STATE/logs/$(date +%Y%m%d-%H%M%S)}"
  mkdir -p "$destination"
  # hb.log goes first; a failed copy never replaces a complete earlier capture.
  for name in hb.log wine-stderr.log; do
    partial="$(mktemp "$destination/$name.partial.XXXXXX")"
    if copy_from_app "$udid" "$APP" "Documents/$name" "$partial"; then
      mv -f "$partial" "$destination/$name"
      copied=1
      log "$name -> $destination/$name"
    else
      failed=1
      warn "could not copy Documents/$name; incomplete capture retained at $partial"
    fi
  done
  [ "$copied" = 1 ] || die "no ios-wine logs were present"
  [ "$failed" = 0 ] || die "log capture is incomplete; check the .partial files"
}

cmd_sync_tree() {
  local source="${1:-$ROOT/out/wine-core}" udid
  [ -d "$source" ] || die "Wine tree not found: $source"
  [ -f "$source/TREE_VERSION" ] || die "$source has no TREE_VERSION"
  udid="$(phone_udid)"
  log "syncing tree $(cat "$source/TREE_VERSION") -> $APP/Documents/wine"
  xcrun devicectl device copy to --device "$udid" \
    --domain-type appDataContainer --domain-identifier "$APP" \
    --source "$source" --destination "Documents/wine" \
    --remove-existing-content true --timeout "$BULK_TIMEOUT"
}

cmd_sync_fex() {
  local source="${1:-$ROOT/out/wine-core/lib/wine/aarch64-windows/libarm64ecfex.dll}" udid pe_dir
  [ -f "$source" ] || die "FEX module not found: $source"
  udid="$(phone_udid)"
  pe_dir="Documents/wine/lib/wine/aarch64-windows"
  log "syncing $(basename "$source") -> $APP/$pe_dir"
  # Wine asks for xtajit64.dll but maps libarm64ecfex.dll; keep both identical.
  copy_to_app "$udid" "$APP" "$source" "$pe_dir/libarm64ecfex.dll"
  copy_to_app "$udid" "$APP" "$source" "$pe_dir/xtajit64.dll"
}

case "${1:-}" in
  logs)      shift; cmd_logs "$@" ;;
  sync-tree) shift; cmd_sync_tree "$@" ;;
  sync-fex)  shift; cmd_sync_fex "$@" ;;
  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac

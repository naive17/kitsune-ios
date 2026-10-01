#!/bin/bash
# Push input lines (syntax: remote_run_line in src/ios/input_overlay.m) to the
# running app, then screenshot it. Coordinates are Wine screen pixels:
# screenshot pixels * render scale / 3 on a 3x phone (2/3 by default).
#   bash scripts/dev/remote.sh [--wait MS] "click 186 480" "sleep 800" ...
#   bash scripts/dev/remote.sh --shot
source "$(dirname "$0")/../common.sh"
UDID=$(phone_udid)
APP=${APP:-$APP_ID}
SHOT=${SHOT:-/tmp/kitsune-shot.png}
WAIT=1500
if [ "${1:-}" = "--wait" ]; then WAIT=$2; shift 2; fi
if [ "${1:-}" != "--shot" ] && [ $# -gt 0 ]; then
  tmp=$(mktemp); printf '%s\n' "$@" > "$tmp"
  xcrun devicectl device copy to --device $UDID --domain-type appDataContainer --domain-identifier $APP \
    --source "$tmp" --destination Documents/remote-input.txt --timeout 30 >/dev/null 2>&1 || echo "push failed"
  rm -f "$tmp"
  sleep $(awk "BEGIN{print $WAIT/1000}")
fi
xcrun devicectl device capture screenshot --device $UDID --destination "$SHOT" --timeout 30 >/dev/null 2>&1 || { echo "screenshot failed"; exit 1; }
sips -Z 1000 "$SHOT" --out "$SHOT.small.png" >/dev/null 2>&1
echo "$SHOT.small.png"

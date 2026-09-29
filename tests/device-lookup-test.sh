#!/usr/bin/env bash
# phone_udid and livecontainer_bundle_id against stubbed devicectl listings; no
# phone is contacted.
set -euo pipefail
source "$(dirname "$0")/../scripts/common.sh"
devices_json=""
apps_json=""
xcrun() {
  local out="" kind=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --json-output) out="$2" ;;
      list) kind=devices ;;
      apps) kind=apps ;;
    esac
    shift
  done
  if [ "$kind" = apps ]; then printf '%s' "$apps_json" > "$out"; else printf '%s' "$devices_json" > "$out"; fi
}
phone() {
  printf '{"hardwareProperties":{"deviceType":"%s","udid":"%s","reality":"physical"},"connectionProperties":{"pairingState":"%s"}}' "$1" "$2" "$3"
}
app() { printf '{"name":"%s","bundleIdentifier":"%s"}' "$1" "$2"; }
devices() { local IFS=,; devices_json="{\"result\":{\"devices\":[$*]}}"; }
apps() { local IFS=,; apps_json="{\"result\":{\"apps\":[$*]}}"; }
refused() {
  if "$@" >/dev/null 2>&1; then echo "FAIL: accepted $*"; exit 1; fi
}

devices "$(phone iPhone AAA paired)" "$(phone iPad BBB paired)" "$(phone iPhone CCC unpaired)"
[ "$(phone_udid)" = AAA ]
UDID=explicit
[ "$(phone_udid)" = explicit ]
unset UDID
devices "$(phone iPhone AAA paired)" "$(phone iPhone DDD paired)"
refused phone_udid
devices
refused phone_udid
devices_json="not json"
refused phone_udid

apps "$(app Settings com.apple.Preferences)" "$(app LiveContainer com.kdt.livecontainer.TEAM)"
[ "$(livecontainer_bundle_id AAA)" = com.kdt.livecontainer.TEAM ]
LIVECONTAINER=chosen
[ "$(livecontainer_bundle_id AAA)" = chosen ]
unset LIVECONTAINER
apps "$(app LiveContainer one)" "$(app LiveContainer two)"
refused livecontainer_bundle_id AAA
apps
refused livecontainer_bundle_id AAA
echo "DEVICE LOOKUP PASS: one paired iPhone and one LiveContainer chosen, overrides win, none or several refused"

#!/bin/bash
# Launch a request under StikDebug JIT until Wine is confirmed booted (the new
# process's hb.log reaches __wine_main), retrying up to max-cycles times; a JIT
# arena below minimum-arena-MB also fails the attempt.
# Usage: ensure-jit-run.sh <request.json> [max-cycles] [minimum-arena-MB]
source "$(dirname "$0")/common.sh"
set +e +o pipefail   # every device step below is checked and retried explicitly
UDID=$(phone_udid) || exit 2
APP=${APP:-$APP_ID}
LIVECONTAINER=$(livecontainer_bundle_id "$UDID") || exit 2
REQ=$1
CYCLES=${2:-6}
MIN_ARENA_MB=${3:-0}
[[ "$MIN_ARENA_MB" =~ ^[0-9]+$ ]] || { echo "minimum-arena-MB must be numeric"; exit 2; }
SP="$ROOT/.deploy/jit-run"
mkdir -p "$SP"
cd "$ROOT"
D="xcrun devicectl device copy from --device $UDID --domain-type appDataContainer --domain-identifier $APP"
U="xcrun devicectl device copy to --device $UDID --domain-type appDataContainer --domain-identifier $APP"
pids(){
  local listing
  if ! listing=$(xcrun devicectl device info processes --device "$UDID" --timeout 30 2>&1); then
    echo "Device process query failed; not assuming the app is absent: $listing" >&2
    return 2
  fi
  printf '%s\n' "$listing" | grep -E "/Kitsune\.app/Kitsune( |$)" | awk '{print $1}' | head -1
}

script_data="$(base64 < jit-scripts/kitsune.js | tr -d '\n' | jq -Rr '@uri')"
inner="stikjit://enable-jit?bundle-id=$APP&script-data=$script_data"
encoded="$(printf '%s' "$inner" | base64 | tr -d '\n' | jq -Rr '@uri')"
outer="livecontainer://open-url?url=$encoded"

for c in $(seq 1 "$CYCLES"); do
  echo "=== cycle $c/$CYCLES ==="
  P=$(pids) || exit 2
  [ -n "$P" ] && { xcrun devicectl device process signal --signal SIGKILL --pid "$P" --device "$UDID" --timeout 30 >/dev/null 2>&1; echo "killed old pid $P"; sleep 3; }
  $U --source "$REQ" --destination Documents/launch-request.json --timeout 40 >/dev/null 2>&1 || { echo "request push failed"; continue; }
  ok=0
  for i in 1 2 3; do
    r=$(xcrun devicectl device process launch --device "$UDID" --terminate-existing --payload-url "$outer" "$LIVECONTAINER" --timeout 60 2>&1 | tail -1)
    echo "  launch try $i: $(echo "$r" | cut -c1-80)"
    echo "$r" | grep -q "Launched application" && { ok=1; break; }
    sleep 8
  done
  [ "$ok" = 1 ] || continue
  # StikDebug may still be attaching; poll so a fresh app is not killed.
  NEWPID=
  for i in 1 2 3; do
    sleep 10
    NEWPID=$(pids) || exit 2
    echo "  app check $i pid: ${NEWPID:-none}"
    [ -n "$NEWPID" ] && break
  done
  [ -n "$NEWPID" ] || continue
  for i in 1 2 3 4 5; do
    sleep 15
    rm -f "$SP/hbchk.log" "$SP/snapchk.log"
    $D --source Documents/hb.log --destination "$SP/hbchk.log" --timeout 40 >/dev/null 2>&1 || {
      echo "Log transport failed; leaving the app running instead of cycling blindly"
      exit 2
    }
    if grep -q "JIT-NOT-ENABLED" "$SP/hbchk.log"; then
      echo "  the app started without JIT"
      break
    fi
    if grep -q "STARTUP os_pid=$NEWPID " "$SP/hbchk.log" && grep -q "calling __wine_main" "$SP/hbchk.log"; then
      # hb.log is truncated at every start, so this is the new process; the
      # arena line is in Wine's own log.
      $D --source Documents/wine-stderr.log --destination "$SP/snapchk.log" --timeout 40 >/dev/null 2>&1 || true
      if [ "$MIN_ARENA_MB" -gt 0 ]; then
        bounds=$(sed -nE 's/.*ios: arena (0x[0-9a-fA-F]+)-(0x[0-9a-fA-F]+) .*/\1 \2/p' "$SP/snapchk.log" | head -1)
        if [ -z "$bounds" ]; then
          echo "  waiting for arena size diagnostic"
          continue
        fi
        read -r arena_start arena_end <<< "$bounds"
        arena_mb=$(( (arena_end - arena_start) / 1048576 ))
        echo "  arena: $arena_mb MB (minimum $MIN_ARENA_MB MB)"
        if [ "$arena_mb" -lt "$MIN_ARENA_MB" ]; then
          echo "  undersized JIT arena -- retrying placement"
          break
        fi
      fi
      echo "JIT-RUN-CONFIRMED pid=$NEWPID cycle=$c"
      echo "$NEWPID" > "$SP/current-jit-pid"
      exit 0
    fi
    echo "  boot check $i: Wine has not started yet"
    p2=$(pids) || exit 2
    [ -z "$p2" ] && { echo "  app died during verify"; break; }
  done
  echo "  requested Wine/JIT conditions not met -- cycling"
done
echo "FAILED: no JIT run after $CYCLES cycles"
exit 1

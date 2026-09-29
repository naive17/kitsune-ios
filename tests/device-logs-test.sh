#!/usr/bin/env bash
# Exercise the actual capture function without an iPhone or Xcode.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
capture_test_dir="$(mktemp -d /tmp/ioswine-log-test.XXXXXX)"
trap 'rm -rf "$capture_test_dir"' EXIT
STATE="$capture_test_dir"
APP=test-app
phone_udid() { printf 'test-device\n'; }
log() { :; }
warn() { printf '%s\n' "$*" >&2; }
die() { printf '%s\n' "$*" >&2; exit 1; }
copy_from_app() {
  printf '%s\n' "$3" >> "$capture_test_dir/order"
  if [ "${fail_wine:-0}" = 1 ] && [ "$3" = Documents/wine-stderr.log ]; then
    printf 'incomplete\n' > "$4"
    return 1
  fi
  printf 'complete %s\n' "$3" > "$4"
}
eval "$(sed -n '/^cmd_logs() {$/,/^}$/p' "$ROOT/scripts/device.sh")"

cmd_logs "$capture_test_dir/capture"
[ "$(head -n 1 "$capture_test_dir/order")" = Documents/hb.log ]
[ "$(cat "$capture_test_dir/capture/wine-stderr.log")" = 'complete Documents/wine-stderr.log' ]
if (fail_wine=1; cmd_logs "$capture_test_dir/capture"); then
  printf 'FAIL: incomplete capture reported success\n' >&2
  exit 1
fi
[ "$(cat "$capture_test_dir/capture/wine-stderr.log")" = 'complete Documents/wine-stderr.log' ]
partials=("$capture_test_dir/capture/"*.partial.*)
[ "${#partials[@]}" = 1 ]
[ "$(cat "${partials[0]}")" = incomplete ]
cmd_logs "$capture_test_dir/capture"
[ "$(cat "$capture_test_dir/capture/wine-stderr.log")" = 'complete Documents/wine-stderr.log' ]
printf 'log capture PASS: startup first, atomic completion, partial retention, failure status\n'

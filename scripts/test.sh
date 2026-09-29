#!/usr/bin/env bash
# Host-side unit tests: tests/*.sh, tests/*.mjs under Node, and tests/*_test.m
# built with UBSan. Prints the output of each failing test and the SKIP line of
# a test whose built inputs are missing; exits non-zero on failure.
source "$(dirname "$0")/common.sh"
set +e
cd "$ROOT"
mkdir -p .deploy/tests
log_file=$(mktemp)
pass=0
fail=0

report() {
  if [ "$1" -eq 0 ]; then
    pass=$((pass + 1))
    grep '^SKIP' "$log_file" || true
  else
    fail=$((fail + 1))
    echo "FAIL $2"
    tail -20 "$log_file" | sed 's/^/  /'
  fi
}

for t in tests/*.sh; do
  bash "$t" >"$log_file" 2>&1
  report $? "$t"
done
for t in tests/*.mjs; do
  node "$t" >"$log_file" 2>&1
  report $? "$t"
done
for t in tests/*_test.m; do
  bin=.deploy/tests/$(basename "$t" .m)
  xcrun --sdk macosx clang -fobjc-arc -fmodules -framework Foundation -fsanitize=undefined \
    -Wall -Wextra -Werror "$t" -o "$bin" >"$log_file" 2>&1 && "$bin" >>"$log_file" 2>&1
  report $? "$t"
done
rm -f "$log_file"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]

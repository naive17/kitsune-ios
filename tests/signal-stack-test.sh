#!/bin/sh
# Build and run tests/signal_stack_test.c: on Apple silicon, Darwin's saved
# signal context overlaps Wine's exception payload unless the handler runs on
# an alternate stack.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/.deploy/tests/signal-stack-test"
mkdir -p "$(dirname "$BIN")"
xcrun --sdk macosx clang -Wall -Wextra -Werror "$ROOT/tests/signal_stack_test.c" -o "$BIN"
"$BIN"

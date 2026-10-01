#!/usr/bin/env bash
# Build the session host, the root process of every Wine session the app runs
# (src/session/session.c), into the directory given.
set -euo pipefail
source "$(dirname "$0")/../common.sh"
dest="${1:?usage: build-session-host.sh <directory>}"
mkdir -p "$dest"
"$MINGW_BIN/aarch64-w64-mingw32-clang" -O2 -ffixed-x28 -Wall -Wextra -Werror -nostdlib \
  "$ROOT/src/session/session.c" \
  -Wl,--entry,mainCRTStartup -Wl,--subsystem,windows -Wl,--section-alignment,0x10000 \
  -lkernel32 -luser32 -o "$dest/kitsune-session.exe"

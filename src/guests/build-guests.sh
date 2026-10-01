#!/usr/bin/env bash
# Build the NATIVE ARM64 guest programs that 21-regress.sh runs into
# build/guests; 20-test-layout.sh builds and stages them.
#
#   inputprobe.exe  input-probe.c  reports the input a window received
#   fpsprobe.exe    fps-probe.c    paints continuously and reports the rate
#
# Separate from src/fex/build-x64-guests.sh, which builds x86-64 guests to
# exercise the emulator. These are aarch64 PE and exercise Wine itself -- the
# window, message and input paths -- with no translation involved, so a failure
# here cannot be blamed on FEX.
#
# --section-alignment=0x10000 for the same reason as the x86-64 guests: lld
# defaults to 4 KB and both the phone and this Mac have 16 KB pages, so .text
# would share a page with .rdata and Wine would be asked for a page that is
# writable and executable at once, which iOS cannot produce.
set -euo pipefail
source "$(dirname "$0")/../../scripts/common.sh"

CC="$MINGW_BIN/aarch64-w64-mingw32-clang"
[ -x "$CC" ] || die "no aarch64 PE cross-compiler; run 01-toolchain.sh"
OUTDIR="$BUILD/guests"
mkdir -p "$OUTDIR"

for pair in inputprobe:input-probe fpsprobe:fps-probe; do
  name="${pair%%:*}"
  src="$ROOT/src/guests/${pair#*:}.c"
  rm -f "$OUTDIR/$name.exe"
  # -ffixed-x28 for the same reason every Wine translation unit gets it: the
  # TEB lives in x28 because Darwin zeroes x18 on preemption, and a PE built
  # without it uses x28 as an ordinary callee-saved register and destroys it.
  # -nostdlib for the same reason: mingw's prebuilt crt2.o is compiled without
  # -ffixed-x28, so the guests bring their own entry point and call kernel32
  # directly.
  "$CC" -O1 -Wall -ffixed-x28 -nostdlib -Wl,--entry=mainCRTStartup \
        -Wl,--section-alignment=0x10000 -Wl,--file-alignment=0x1000 \
        "$src" -luser32 -lgdi32 -lkernel32 -o "$OUTDIR/$name.exe" \
        2>&1 | grep -v "align specified" || true
  [ -f "$OUTDIR/$name.exe" ] || die "failed to build $name.exe"
  m="$("$MINGW_BIN/llvm-readobj" --file-headers "$OUTDIR/$name.exe" | awk '/Machine:/{print $NF}')"
  [ "$m" = "(0xAA64)" ] || die "$name.exe is $m, expected ARM64"
  log "$name.exe  machine=$m"
done

#!/usr/bin/env bash
# Build the x86-64 guest programs that 21-regress.sh runs under FEX into
# build/x64-guests; 20-decoy-split.sh builds and stages them.
#
#   hello64.exe     x64-hello.c        prints a 64-bit product: x86-64 code was
#                                      translated, written through the RW alias
#                                      of the dual-mapped arena and run at RX
#   seh64.exe       x64-seh-resume.c   a fault in translated code is delivered
#                                      and execution resumes, twice
#   sehcross64.exe  x64-seh-cross.c    a fault in ARM64EC code reaches the
#                                      handler of the x86 frame that called it
#
# All are -nostdlib with a custom entry point on purpose: the first x86
# instruction executed is then one we can point at, and a failure cannot be
# blamed on mingw's startup code.
#
# --section-alignment=0x10000 is NOT cosmetic. lld defaults to 4 KB, and both
# the phone and this Mac have 16 KB pages, so .text would share a page with
# .rdata and Wine would be asked for a write+execute page that iOS cannot
# produce:
#   err:virtual:mprotect_exec ios: ... wants write+exec, which cannot exist here
source "$(dirname "$0")/../../scripts/common.sh"

CC="$MINGW_BIN/x86_64-w64-mingw32-clang"
[ -x "$CC" ] || die "no x86_64 PE cross-compiler; run 01-toolchain.sh"
OUTDIR="$BUILD/x64-guests"
mkdir -p "$OUTDIR"

for pair in hello64:x64-hello seh64:x64-seh-resume sehcross64:x64-seh-cross; do
  name="${pair%%:*}"
  src="$ROOT/src/fex/${pair#*:}.c"
  rm -f "$OUTDIR/$name.exe"
  # 2>&1 | grep -v: lld warns "/align specified without /driver", which is a
  # Windows-driver-signing concern and irrelevant to a Wine guest.
  "$CC" -O1 -nostdlib -Wl,--entry=mainCRTStartup \
        -Wl,--section-alignment=0x10000 -Wl,--file-alignment=0x1000 \
        "$src" -lkernel32 -o "$OUTDIR/$name.exe" 2>&1 | grep -v "align specified" || true
  [ -f "$OUTDIR/$name.exe" ] || die "failed to build $name.exe"
  m="$("$MINGW_BIN/llvm-readobj" --file-headers "$OUTDIR/$name.exe" | awk '/Machine:/{print $NF}')"
  [ "$m" = "(0x8664)" ] || die "$name.exe is $m, expected AMD64 -- it must be x86-64 to test anything"
  log "$name.exe  machine=$m"
done

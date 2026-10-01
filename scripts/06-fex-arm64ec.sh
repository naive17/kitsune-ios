#!/usr/bin/env bash
# Build FEX's ARM64EC emulator (libarm64ecfex.dll), the x86-64 CPU backend for
# ARM64EC processes, into out/fex/.
# Requires 02-fetch.sh; downloads the bylaws llvm-mingw pinned in pins.env.
source "$(dirname "$0")/common.sh"

FEX_SRC="$THIRD_PARTY/fex"
B="$BUILD/fex-arm64ec"
[ -d "$FEX_SRC" ] || die "run 02-fetch.sh first"

# A later patch edits an earlier one's lines (0007 changes a line 0001 adds), so
# apply_patch's per-patch reverse check cannot recognise a patched tree.
# Reset the source to the pin and apply the whole stack in order. This discards
# local edits in third_party/fex; changes belong in patches/fex/.
log "resetting FEX source to the pin before applying the patch stack"
git -C "$FEX_SRC" checkout -- . 
git -C "$FEX_SRC/External/rpmalloc" checkout -- . 2>/dev/null || true
git -C "$FEX_SRC" clean -fdq -- FEXCore Source CodeEmitter
apply_patch "$FEX_SRC" "$ROOT/patches/fex/0001-dual-mapped-jit-memory.patch"

# rpmalloc is a submodule, so its patch (0002) applies inside it.
apply_patch "$FEX_SRC/External/rpmalloc" "$ROOT/patches/fex/0002-rpmalloc-reserve-aligned.patch"
apply_patch "$FEX_SRC" "$ROOT/patches/fex/0003-lazy-lookupcache.patch"
apply_patch "$FEX_SRC" "$ROOT/patches/fex/0004-unaligned-tso-inline-check.patch"
apply_patch "$FEX_SRC" "$ROOT/patches/fex/0005-readable-pages-are-decodable.patch"
apply_patch "$FEX_SRC" "$ROOT/patches/fex/0006-fex-vm-skips-wine-notify.patch"
apply_patch "$FEX_SRC" "$ROOT/patches/fex/0007-configurable-dual-mapped-code-buffer.patch"
apply_patch "$FEX_SRC" "$ROOT/patches/fex/0008-callret-stack-host-page-guards.patch"
apply_patch "$FEX_SRC" "$ROOT/patches/fex/0009-lookupcache-24mb-per-thread.patch"
apply_patch "$FEX_SRC" "$ROOT/patches/fex/0010-quiet-debug-log.patch"
apply_patch "$FEX_SRC" "$ROOT/patches/fex/0011-retire-stale-code-buffers.patch"
apply_patch "$FEX_SRC" "$ROOT/patches/fex/0012-trap-rwx-code-per-host-page.patch"
apply_patch "$FEX_SRC" "$ROOT/patches/fex/0013-write-alias-query-without-loader-lock.patch"
apply_patch "$FEX_SRC" "$ROOT/patches/fex/0014-trap-per-4k-inside-the-arena.patch"

# FEX needs bylaws' llvm-mingw; the upstream release crashes in the ARM64EC SEH
# unwind emitter (see pins.env).
FEX_TC="$TOOLCHAINS/llvm-mingw-$FEX_MINGW_VER-bylaws"
if [ ! -x "$FEX_TC/bin/clang" ]; then
  url="https://github.com/$FEX_MINGW_REPO/releases/download/$FEX_MINGW_VER/$FEX_MINGW_ASSET"
  log "downloading bylaws llvm-mingw $FEX_MINGW_VER (FEX ARM64EC toolchain)"
  curl -fL --retry 3 -o "$TOOLCHAINS/$FEX_MINGW_ASSET" "$url"
  tar -xJf "$TOOLCHAINS/$FEX_MINGW_ASSET" -C "$TOOLCHAINS"
  mv "$TOOLCHAINS/${FEX_MINGW_ASSET%.tar.xz}" "$FEX_TC"
  rm -f "$TOOLCHAINS/$FEX_MINGW_ASSET"
  xattr -dr com.apple.quarantine "$FEX_TC" 2>/dev/null || true
fi
[ -x "$FEX_TC/bin/arm64ec-w64-mingw32-clang" ] || die "bylaws toolchain missing arm64ec driver"
# Prepend so it wins over the mstorsjo toolchain that common.sh puts on PATH.
export PATH="$FEX_TC/bin:$PATH"
log "FEX toolchain: $("$FEX_TC/bin/clang" --version | head -1)"

# This port keeps the TEB in x28 because Darwin zeroes x18 on every exception
# return. mingw-w64's NtCurrentTeb() reads x18 and is FORCEINLINE, so no -D or
# forced include can override it; winnt.h is patched in place in both include
# trees of this toolchain, which builds nothing but FEX. clang allows a global
# register variable only on x18, hence inline asm, kept non-volatile so it still
# CSEs (x28 never changes within a thread).
patch_teb_header() {
  local h="$1"
  [ -f "$h" ] || return 0
  # 'ios-wine:' is the marker from before the rename; a cached toolchain has it.
  if grep -q -e 'Kitsune: TEB in x28' -e 'ios-wine: TEB in x28' "$h"; then
    log "  already patched: $h"; return 0
  fi
  grep -q '__mingw_current_teb __asm__("x18")' "$h" \
    || die "unexpected NtCurrentTeb() in $h -- toolchain changed, re-check by hand"
  perl -0pi -e 's{    register struct _TEB \*__mingw_current_teb __asm__\("x18"\);\n    FORCEINLINE struct _TEB \*NtCurrentTeb\(VOID\)\n    \{\n        return __mingw_current_teb;\n    \}\n}{    FORCEINLINE struct _TEB *NtCurrentTeb(VOID)\n    \{\n        /* Kitsune: TEB in x28, not x18 -- Darwin zeroes x18 on preemption.\n           Non-volatile asm so this still CSEs; x28 never changes in a thread. */\n        struct _TEB *__ios_teb;\n        __asm__ ("mov %0, x28" : "=r" (__ios_teb));\n        return __ios_teb;\n    \}\n}' "$h"
  grep -q 'Kitsune: TEB in x28' "$h" || die "TEB patch did not apply to $h"
  log "  patched NtCurrentTeb() -> x28 in $h"
}
log "pointing mingw-w64's NtCurrentTeb() at x28"
patch_teb_header "$FEX_TC/aarch64-w64-mingw32/include/winnt.h"
patch_teb_header "$FEX_TC/arm64ec-w64-mingw32/include/winnt.h"

# FEX's default TUNE_CPU=native reads /proc/cpuinfo, which macOS lacks, and would
# tune for the build host rather than the device, so configure passes apple-m1,
# which A15/M2 and newer implement.

# Force FEX's bundled External/ dependencies: CMake otherwise finds Homebrew's
# Mach-O builds despite the toolchain file's find-root mode, and configure fails
# with "IMPORTED_IMPLIB not set". Python and Git stay enabled as host tools.
NO_HOST_PKGS=()
for p in fmt unordered_dense Zycore Zydis xxhash Catch2 range-v3; do
  NO_HOST_PKGS+=("-DCMAKE_DISABLE_FIND_PACKAGE_${p}=ON")
done

# lld's default 4 KB section alignment puts several sections in one 16 KB page,
# which Wine would have to map writable and executable at once; iOS forbids that.
# 64 KB, as Wine's own PE modules use, gives each section its own page.
EXTRA_LDFLAGS="-Wl,--section-alignment=0x10000"

# FEX_HOST_DARWIN (patch 0001) stubs out FEX's raw Linux syscall fallbacks, which
# raise SIGSYS on Darwin. FEX_IOS enables patch 0004: unaligned atomics are
# checked inline, because FEX cannot back-patch an iOS JIT page after an
# alignment fault.
EXTRA_CXXFLAGS="-DFEX_HOST_DARWIN -DFEX_IOS"

log "configuring FEX arm64ec (toolchain: $(which arm64ec-w64-mingw32-clang))"
cmake -S "$FEX_SRC" -B "$B" -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_TOOLCHAIN_FILE="$FEX_SRC/Data/CMake/toolchain_mingw.cmake" \
  -DMINGW_TRIPLE=arm64ec-w64-mingw32 \
  -DTUNE_CPU=apple-m1 \
  -DENABLE_LTO=False \
  -DBUILD_TESTING=False \
  -DCMAKE_SHARED_LINKER_FLAGS="$EXTRA_LDFLAGS" \
  -DCMAKE_CXX_FLAGS="$EXTRA_CXXFLAGS" \
  "${NO_HOST_PKGS[@]}" \
  > "$BUILD/fex-configure.log" 2>&1 \
  || { grep -A12 "CMake Error" "$BUILD/fex-configure.log" | head -40; die "configure failed (see $BUILD/fex-configure.log)"; }

log "building arm64ecfex (-j4: -j8 runs an 8 GB Mac out of memory on FEXCore)"
cmake --build "$B" --target arm64ecfex -j4

art="$(find "$B" -name 'libarm64ecfex.dll' | head -1)"
[ -n "$art" ] || die "libarm64ecfex.dll not produced"

mkdir -p "$OUT/fex"
cp "$art" "$OUT/fex/"
mach="$("$FEX_TC/bin/llvm-readobj" --file-headers "$art" | awk '/Machine:/{print $NF}')"
log "libarm64ecfex.dll  machine=$mach  size=$(du -h "$art" | cut -f1)"
[ "$mach" = "(0xA641)" ] || die "not an ARM64EC image (got $mach)"

align="$("$FEX_TC/bin/llvm-readobj" --file-headers "$art" | awk '/SectionAlignment/{print $NF}')"
log "SectionAlignment: $align"
[ "$((align))" -ge 16384 ] || die "SectionAlignment $align < 16384; sections will share pages"

# The emulator may import only ntdll. Any other DLL loads as its dependency
# before arm64ec_process_init() sets the __os_arm64x_dispatch_* pointers, so its
# dispatch slots are filled with NULL and its first return to x86 code jumps to 0.
imports="$("$FEX_TC/bin/llvm-readobj" --coff-imports "$art" | awk '/^ *Name:/{print $2}' | sort -u)"
log "imports: $(echo "$imports" | tr '\n' ' ')"
[ "$imports" = "ntdll.dll" ] || die "libarm64ecfex.dll must import only ntdll.dll; got: $imports"

# clang never allocates x18 on Windows targets, so any x18 left in the image is
# a TEB read from a register Darwin zeroes.
dis="$BUILD/fex-x18-scan.txt"
"$FEX_TC/bin/llvm-objdump" -d "$art" > "$dis" 2>/dev/null
# LC_ALL=C: BSD grep matches nothing in input that is not valid UTF-8, which
# would make this check always pass.
n18="$(LC_ALL=C grep -cE '\bx18\b' "$dis" || true)"
log "x18 references in the shipped image: $n18"
if [ "$n18" -ne 0 ]; then
  warn "remaining x18 (TEB) references -- these will read a zeroed register:"
  LC_ALL=C perl -ne 'BEGIN{$s="?"} if(/^[0-9a-f]+ <(.*)>:$/){$s=$1;next}
                     print "    $s: $_" if /\bx18\b/' "$dis" | sort -u | head -20
  die "libarm64ecfex.dll still reads the TEB from x18"
fi

log "ARM64EC-FEX PASSED"

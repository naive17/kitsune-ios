#!/bin/sh
# Host tests for the launcher's PE detection and archive extraction, built from
# src/host/pe_zip_test.c. Every check matches an expected string, so a
# subcommand that prints nothing fails.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD="$ROOT/build/launcher-test"
BIN="$BUILD/pe_zip_test"
WORK="$BUILD/work"
FAIL=0

mkdir -p "$BUILD"
rm -rf "$WORK"
mkdir -p "$WORK"

echo "== building pe_zip_test =="
xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror -O1 -g \
  "$ROOT/src/host/pe_zip_test.c" "$ROOT/src/ios/pe_info.c" "$ROOT/src/ios/zip.c" \
  -lz -o "$BIN"

check() { # check <label> <expected-substring> <actual>
  if printf '%s' "$3" | grep -q -- "$2"; then
    echo "  ok   $1"
  else
    echo "  FAIL $1"
    echo "       wanted: $2"
    echo "       got:    $3"
    FAIL=$((FAIL + 1))
  fi
}

echo "== PE machine detection =="
PE="$ROOT/out/wine-tree/lib/wine/aarch64-windows"
HELLO="$ROOT/build/x64-guests/hello64.exe"
if [ -f "$HELLO" ]; then
  check "hello64.exe is x86-64"      "arch=x86-64"  "$("$BIN" pe "$HELLO")"
  check "hello64.exe is 64-bit"      "bits=64"      "$("$BIN" pe "$HELLO")"
  check "hello64.exe is not a DLL"   "dll=0"        "$("$BIN" pe "$HELLO")"
else
  echo "  skip hello64.exe (not built; src/fex/build-x64-guests.sh)"
fi
if [ -f "$PE/notepad.exe" ]; then
  # ARM64X or ARM64EC depending on how the module was emitted; both are native.
  check "notepad.exe is native ARM"  "arch=ARM64"   "$("$BIN" pe "$PE/notepad.exe")"
fi
if [ -f "$PE/ntdll.dll" ]; then
  check "ntdll.dll is a DLL"         "dll=1"        "$("$BIN" pe "$PE/ntdll.dll")"
fi

check "non-PE is rejected" "ERROR not a PE image" "$("$BIN" pe "$ROOT/pins.env" || true)"
check "missing file is rejected" "ERROR cannot open" "$("$BIN" pe "$WORK/nope.exe" || true)"

echo "== archive path validation =="
check "plain path"          "ACCEPT a/b.exe -> a/b.exe"  "$("$BIN" path 'a/b.exe')"
check "backslashes"         "ACCEPT" "$("$BIN" path 'a\b\c.dll')"
check "backslashes join"    "> a/b/c.dll"                 "$("$BIN" path 'a\b\c.dll')"
check "dot segments"        "-> a/b"                      "$("$BIN" path 'a/./b')"
check "traversal"           "REJECT" "$("$BIN" path '../escape')"
check "nested traversal"    "REJECT" "$("$BIN" path 'a/../../escape')"
check "absolute"            "REJECT" "$("$BIN" path '/etc/passwd')"
check "windows absolute"    "REJECT" "$("$BIN" path '\\windows\\system32')"
check "drive letter"        "REJECT" "$("$BIN" path 'C:/windows')"

echo "== ordinary archive round-trip =="
mkdir -p "$WORK/src/game/data"
printf 'MZ-not-really' > "$WORK/src/game/game.exe"
printf 'library' > "$WORK/src/game/engine.dll"
# Big enough that it is actually deflated rather than stored.
awk 'BEGIN{for(i=0;i<20000;i++) printf "compress me "}' > "$WORK/src/game/data/assets.txt"
( cd "$WORK/src" && zip -q -r "$WORK/good.zip" game )

OUT=$("$BIN" unzip "$WORK/good.zip" "$WORK/out-good")
check "extracts with nothing skipped" "skipped=0" "$OUT"
[ -f "$WORK/out-good/game/game.exe" ]        && echo "  ok   game.exe present"        || { echo "  FAIL game.exe missing"; FAIL=$((FAIL+1)); }
[ -f "$WORK/out-good/game/engine.dll" ]      && echo "  ok   engine.dll present"      || { echo "  FAIL engine.dll missing"; FAIL=$((FAIL+1)); }
[ -f "$WORK/out-good/game/data/assets.txt" ] && echo "  ok   nested asset present"    || { echo "  FAIL nested asset missing"; FAIL=$((FAIL+1)); }

if diff -r "$WORK/src/game" "$WORK/out-good/game" >/dev/null 2>&1; then
  echo "  ok   extracted tree is identical to the source"
else
  echo "  FAIL extracted tree differs from the source"
  FAIL=$((FAIL + 1))
fi

# Built with Python's zipfile because zip(1) refuses to write these names.
echo "== hostile archive is refused, entry by entry =="
python3 - "$WORK/evil.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("../escaped.txt", "should never be written")
    z.writestr("a/../../escaped2.txt", "should never be written")
    z.writestr("/absolute.txt", "should never be written")
    z.writestr("good/keep.txt", "this one is fine")
    # A symlink entry: unix mode S_IFLNK|0777 in the high half of external_attr.
    info = zipfile.ZipInfo("good/link")
    info.create_system = 3
    info.external_attr = (0xA1FF << 16)
    z.writestr(info, "../../../../../../etc/passwd")
PY

OUT=$("$BIN" unzip "$WORK/evil.zip" "$WORK/out-evil")
check "hostile entries are skipped" "skipped=4" "$OUT"
[ -f "$WORK/out-evil/good/keep.txt" ] && echo "  ok   the one safe entry was kept" || { echo "  FAIL safe entry was dropped"; FAIL=$((FAIL+1)); }

strays=0
for stray in "$WORK/escaped.txt" "$WORK/out-evil/../escaped.txt" \
             "$BUILD/escaped2.txt" "/absolute.txt" "$WORK/out-evil/good/link"; do
  if [ -e "$stray" ]; then
    echo "  FAIL something was written outside the destination: $stray"
    FAIL=$((FAIL + 1))
    strays=$((strays + 1))
  fi
done
[ "$strays" -eq 0 ] && echo "  ok   nothing was written outside the destination"

if [ "$(find "$WORK/out-good" -type f | wc -l | tr -d ' ')" -eq 3 ]; then
  echo "  ok   the honest archive still produced all 3 files"
else
  echo "  FAIL the honest archive did not produce 3 files"
  FAIL=$((FAIL + 1))
fi

# The app imports on a secondary thread, which iOS gives only 512 KB of stack.
echo "== extraction survives a 512 KB stack (the iOS secondary-thread size) =="
OUT=$("$BIN" unzip-smallstack "$WORK/good.zip" "$WORK/out-smallstack" 2>&1) || true
check "extracts on a 512 KB stack" "skipped=0" "$OUT"
if diff -r "$WORK/src/game" "$WORK/out-smallstack/game" >/dev/null 2>&1; then
  echo "  ok   small-stack output is identical to the source"
else
  echo "  FAIL small-stack extraction did not reproduce the tree"
  FAIL=$((FAIL + 1))
fi

echo "== corrupted payload is not silently accepted =="
cp "$WORK/good.zip" "$WORK/corrupt.zip"
# Flip bytes in the middle of the compressed data, past the first local header.
python3 - "$WORK/corrupt.zip" <<'PY'
import sys
p = sys.argv[1]
b = bytearray(open(p, "rb").read())
for i in range(200, min(400, len(b))):
    b[i] ^= 0xFF
open(p, "wb").write(bytes(b))
PY
OUT=$("$BIN" unzip "$WORK/corrupt.zip" "$WORK/out-corrupt" || true)
if printf '%s' "$OUT" | grep -q "skipped=0"; then
  echo "  FAIL corruption was accepted as valid"
  FAIL=$((FAIL + 1))
else
  echo "  ok   corruption was caught ($OUT)"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "LAUNCHER-TEST PASSED"
else
  echo "LAUNCHER-TEST FAILED ($FAIL checks)"
  exit 1
fi

#!/bin/sh
# Host tests for VZ packages (src/ios/vz.c), the format of Steam's client
# packages. Python's lzma module writes the packages: a stored and a deflated
# zip decode and extract, and damage, truncation and escaping names fail.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD="$ROOT/build/vz-test"
BIN="$BUILD/vz_test"
WORK="$BUILD/work"
FAIL=0

mkdir -p "$BUILD"
rm -rf "$WORK"
mkdir -p "$WORK"

xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror -O1 -g \
  "$ROOT/src/host/vz_test.c" "$ROOT/src/ios/vz.c" "$ROOT/src/ios/zip.c" "$ROOT/src/lzma/LzmaDec.c" \
  -lz -o "$BIN"

check() { # check <label> <expected-substring> <actual>
  if printf '%s' "$3" | grep -q -- "$2"; then
    echo "  ok   $1"
  else
    echo "  FAIL $1: expected '$2', got '$3'"
    FAIL=1
  fi
}

python3 - "$WORK" <<'PY'
import io, lzma, os, struct, sys, zipfile, zlib

work = sys.argv[1]
src = os.path.join(work, "src")
files = {
    "steam.exe": os.urandom(3000),
    "bin/cef/big.dll": os.urandom(2_500_000) + bytes(1_000_000),  # crosses the decode chunks
    "bin/empty.txt": b"",
    "public/steamui.txt": b"interface\n" * 5000,
}
for name, data in files.items():
    path = os.path.join(src, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "wb").write(data)

def zipped(method, names):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", method) as z:
        z.writestr(zipfile.ZipInfo("bin/"), b"")
        for name in names:
            z.writestr(name, files.get(name, b"x"))
    return buf.getvalue()

def vz(data, packed=None):
    props = struct.pack("<BI", (2 * 5 + 0) * 9 + 3, 1 << 25)
    if packed is None:
        packed = lzma.compress(data, format=lzma.FORMAT_RAW,
                               filters=[{"id": lzma.FILTER_LZMA1, "dict_size": 1 << 25, "lc": 3, "lp": 0, "pb": 2}])
    return b"VZa" + struct.pack("<I", 1700000000) + props + packed + struct.pack("<II", zlib.crc32(data), len(data)) + b"zv"

def write(name, blob):
    open(os.path.join(work, name), "wb").write(blob)

stored = zipped(zipfile.ZIP_STORED, files)
write("stored.vz", vz(stored))
write("deflated.vz", vz(zipped(zipfile.ZIP_DEFLATED, files)))
bad = bytearray(vz(stored))
bad[-10] ^= 0xFF
write("badcrc.vz", bytes(bad))
good = vz(stored)
packed = good[12:-10]
write("truncated.vz", vz(stored, packed[: len(packed) // 2]))
write("escape.vz", vz(zipped(zipfile.ZIP_STORED, ["../escape.txt"])))
write("notvz.bin", os.urandom(4096))
PY

OUT=$("$BIN" "$WORK/stored.vz" "$WORK/out-stored" || true)
check "a stored zip decodes and extracts" "vz: ok" "$OUT"
if diff -r "$WORK/src" "$WORK/out-stored" >/dev/null; then echo "  ok   extracted files match"; else echo "  FAIL extracted files differ"; FAIL=1; fi

OUT=$("$BIN" "$WORK/deflated.vz" "$WORK/out-deflated" || true)
check "a deflated zip decodes and extracts" "vz: ok" "$OUT"
if diff -r "$WORK/src" "$WORK/out-deflated" >/dev/null; then echo "  ok   deflated files match"; else echo "  FAIL deflated files differ"; FAIL=1; fi

OUT=$("$BIN" "$WORK/badcrc.vz" "$WORK/out-badcrc" || true)
check "a wrong CRC is refused" "vz: ERROR the package is damaged" "$OUT"

OUT=$("$BIN" "$WORK/truncated.vz" "$WORK/out-truncated" || true)
check "truncated data is refused" "vz: ERROR" "$OUT"

OUT=$("$BIN" "$WORK/escape.vz" "$WORK/out-escape/inner" || true)
check "an escaping name is refused" "vz: ERROR unsafe entry name" "$OUT"
if [ -e "$WORK/out-escape/escape.txt" ]; then echo "  FAIL a file escaped the destination"; FAIL=1; else echo "  ok   nothing escaped"; fi

OUT=$("$BIN" "$WORK/notvz.bin" "$WORK/out-notvz" || true)
check "other files are refused" "vz: ERROR not a VZ package" "$OUT"

exit $FAIL

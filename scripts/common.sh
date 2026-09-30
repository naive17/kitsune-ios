# shellcheck shell=bash
# Sourced by every build script. Sets ROOT, loads pins, defines helpers.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
set -a; source "$ROOT/pins.env"; set +a
# Per-developer settings (see local.env.example); not tracked.
# shellcheck source=/dev/null
if [ -f "$ROOT/local.env" ]; then set -a; source "$ROOT/local.env"; set +a; fi
# The app's bundle id, which the device scripts address.
APP_ID="${KITSUNE_BUNDLE_ID:-dev.kitsune.app}"

# A full Xcode is required: the Command Line Tools lack the iphoneos SDK and
# the libc++ headers. An explicit DEVELOPER_DIR wins; otherwise the first Xcode
# that has the iPhoneOS platform.
if [ -z "${DEVELOPER_DIR:-}" ] || [ ! -d "$DEVELOPER_DIR" ]; then
  DEVELOPER_DIR=""
  for candidate in \
    "$(xcode-select -p 2>/dev/null)" \
    /Applications/Xcode*.app/Contents/Developer \
    /Volumes/*/Xcode*.app/Contents/Developer \
    /Volumes/*/*/Xcode*.app/Contents/Developer \
    "$HOME"/Downloads/Xcode*.app/Contents/Developer
  do
    if [ -d "$candidate/Platforms/iPhoneOS.platform" ]; then
      DEVELOPER_DIR="$candidate"
      break
    fi
  done
fi
[ -n "$DEVELOPER_DIR" ] && export DEVELOPER_DIR

THIRD_PARTY="$ROOT/third_party"
TOOLCHAINS="$ROOT/toolchains"
BUILD="$ROOT/build"
OUT="$ROOT/out"
NPROC="$(sysctl -n hw.ncpu)"

# llvm-mingw goes first: its clang must win over Apple clang for PE targets.
MINGW_BIN="$TOOLCHAINS/llvm-mingw-$LLVM_MINGW_VER/bin"
# Homebrew bison 3.x must precede /usr/bin/bison (2.3), which Wine rejects.
export PATH="$MINGW_BIN:/opt/homebrew/opt/bison/bin:/opt/homebrew/bin:$PATH"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

# Clone at an exact SHA without fetching full history.
pin_clone() {
  local url="$1" sha="$2" dir="$3"
  if [ -d "$dir/.git" ]; then
    if [ "$(git -C "$dir" rev-parse HEAD)" = "$sha" ]; then
      log "$(basename "$dir") already at $sha"; return 0
    fi
  else
    mkdir -p "$dir"; git -C "$dir" init -q
    git -C "$dir" remote add origin "$url"
  fi
  log "fetching $(basename "$dir") @ $sha"
  git -C "$dir" fetch -q --depth 1 origin "$sha"
  git -C "$dir" checkout -q --detach FETCH_HEAD
  git -C "$dir" submodule update -q --init --recursive --depth 1 2>/dev/null || true
  [ "$(git -C "$dir" rev-parse HEAD)" = "$sha" ] || die "$dir: SHA mismatch"
}

# Idempotent patch application against a vendored git checkout.
apply_patch() {
  local repo="$1" p="$2"
  [ -f "$p" ] || die "missing patch $p"
  [ -d "$repo" ] || die "missing repo $repo"
  if git -C "$repo" apply --check --reverse "$p" 2>/dev/null; then
    log "patch already applied in $(basename "$repo"): $(basename "$p")"
  elif git -C "$repo" apply --check "$p" 2>/dev/null; then
    log "applying $(basename "$p") to $(basename "$repo")"
    git -C "$repo" apply "$p"
  else
    die "patch does not apply to $repo: $p. After a pull that changed it, scripts/sync-sources.sh moves the checkout to the current patches"
  fi
}

require_disk_gb() {
  local need="$1"
  local free
  # Check the filesystem that receives the bytes: $2, or build/ by default.
  mkdir -p "${2:-$BUILD}"
  free="$(df -g "${2:-$BUILD}" | tail -1 | awk '{print $4}')"
  [ "$free" -ge "$need" ] || die "need ${need}GB free, have ${free}GB"
}

# The phone that devicectl commands address: $UDID when set, otherwise the only
# paired physical iPhone.
phone_udid() {
  if [ -n "${UDID:-}" ]; then
    printf '%s\n' "$UDID"
    return 0
  fi
  local listing udid
  listing="$(mktemp)"
  xcrun devicectl list devices --json-output "$listing" >/dev/null 2>&1 || true
  udid="$(python3 - "$listing" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except (OSError, ValueError, KeyError, TypeError):
    devices = []
phones = [d["hardwareProperties"]["udid"] for d in devices
          if d.get("hardwareProperties", {}).get("deviceType") == "iPhone"
          and d.get("hardwareProperties", {}).get("reality", "physical") == "physical"
          and d.get("connectionProperties", {}).get("pairingState") == "paired"]
print(phones[0] if len(phones) == 1 else "")
PY
)"
  rm -f "$listing"
  [ -n "$udid" ] || { warn "set UDID: devicectl lists no single paired iPhone"; return 1; }
  printf '%s\n' "$udid"
}

# LiveContainer's bundle id on phone $1: $LIVECONTAINER when set, otherwise the
# one installed app named LiveContainer.
livecontainer_bundle_id() {
  if [ -n "${LIVECONTAINER:-}" ]; then
    printf '%s\n' "$LIVECONTAINER"
    return 0
  fi
  local listing id
  listing="$(mktemp)"
  xcrun devicectl device info apps --device "$1" --json-output "$listing" >/dev/null 2>&1 || true
  id="$(python3 - "$listing" <<'PY'
import json, sys
try:
    apps = json.load(open(sys.argv[1]))["result"]["apps"]
except (OSError, ValueError, KeyError, TypeError):
    apps = []
ids = [a.get("bundleIdentifier", "") for a in apps if a.get("name") == "LiveContainer"]
print(ids[0] if len(ids) == 1 else "")
PY
)"
  rm -f "$listing"
  [ -n "$id" ] || { warn "set LIVECONTAINER: the phone has no single app named LiveContainer"; return 1; }
  printf '%s\n' "$id"
}

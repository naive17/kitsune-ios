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

# Clone at an exact SHA without fetching full history. A checkout with a patch
# series (apply_series) is at its pin when the series sits on it.
pin_clone() {
  local url="$1" sha="$2" dir="$3"
  if [ -d "$dir/.git" ]; then
    if [ "$(git -C "$dir" rev-parse HEAD)" = "$sha" ] ||
       [ "$(git -C "$dir" rev-parse -q --verify refs/kitsune/base)" = "$sha" ]; then
      log "$(basename "$dir") already at $sha"; return 0
    fi
  else
    mkdir -p "$dir"; git -C "$dir" init -q
    git -C "$dir" remote add origin "$url"
  fi
  log "fetching $(basename "$dir") @ $sha"
  git -C "$dir" fetch -q --depth 1 origin "$sha"
  git -C "$dir" checkout -q --detach FETCH_HEAD
  git -C "$dir" update-ref -d refs/kitsune/base 2>/dev/null || true
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

# A patch series is a directory of numbered patches (NNNN-name.patch), each
# its description, a line "---", and the diff; git apply skips the
# description. apply_series commits them in order on top of the checkout's
# pin, so the checkout's history shows the port and git diff there shows only
# unsaved edits. refs/kitsune/base marks the pin. The commits have a fixed
# author and date, so the same series on the same pin gives the same commits.

# series_patches <dir>: the series in order.
series_patches() {
  find "$1" -maxdepth 1 -name '[0-9][0-9][0-9][0-9]-*.patch' | sort
}

# series_base <checkout>: the commit its series sits on.
series_base() {
  git -C "$1" rev-parse -q --verify refs/kitsune/base || git -C "$1" rev-parse HEAD
}

# series_tree <checkout> <base> <dir>: the tree id of <base> with the series
# applied, or nothing when a patch does not apply. Uses a scratch index.
series_tree() {
  local repo="$1" base="$2" dir="$3" idx p
  idx="$(mktemp)"; rm -f "$idx"
  GIT_INDEX_FILE="$idx" git -C "$repo" read-tree "$base"
  for p in $(series_patches "$dir"); do
    GIT_INDEX_FILE="$idx" git -C "$repo" apply --cached --whitespace=nowarn "$p" 2>/dev/null \
      || { rm -f "$idx"; return 0; }
  done
  GIT_INDEX_FILE="$idx" git -C "$repo" write-tree
  rm -f "$idx"
}

# worktree_tree <checkout>: the tree id of its files as they are on disk,
# tracked and untracked, not ignored. A scratch index started from a copy of
# the checkout's own keeps its stat cache, so only changed files are hashed.
# Meson leaves subprojects/.wraplock in DXVK's source tree while it builds.
worktree_tree() {
  local idx
  idx="$(mktemp)"
  cp "$(git -C "$1" rev-parse --absolute-git-dir)/index" "$idx" 2>/dev/null || rm -f "$idx"
  GIT_INDEX_FILE="$idx" git -C "$1" add -A -- . ':(exclude,glob)**/.wraplock' >/dev/null 2>&1 \
    || { rm -f "$idx"; die "$1: git add failed"; }
  GIT_INDEX_FILE="$idx" git -C "$1" write-tree
  rm -f "$idx"
}

# drop_legacy_base <checkout>: DXMT's port used to be one patch over a base
# commit ("Kitsune base", or "ios-wine base" before the rename) on the pin.
# Uncommits it, keeping the files, so the checkout is its pin again and
# apply_series can record the series over the same files.
drop_legacy_base() {
  [[ "$(git -C "$1" log -1 --format=%s 2>/dev/null)" =~ ^(Kitsune|ios-wine)\ base$ ]] || return 0
  git -C "$1" reset -q HEAD^
  log "$(basename "$1"): dropped its old base commit; the files are unchanged"
}

# apply_series <checkout> <dir>: idempotent. A checkout that already holds the
# series is left as it is, unsaved edits included. One whose files are the
# series without its commits (set up before the port was a series) gets the
# commits and keeps its files, so nothing rebuilds.
apply_series() {
  local repo="$1" dir="$2" base want parent p msg idx adopt=0 n=0
  [ -d "$dir" ] || die "missing patch series $dir"
  base="$(series_base "$repo")"
  want="$(series_tree "$repo" "$base" "$dir")"
  [ -n "$want" ] || die "the patches in ${dir#"$ROOT"/} do not apply to $(basename "$repo")'s pin"
  if [ "$(git -C "$repo" rev-parse 'HEAD^{tree}')" = "$want" ]; then
    log "$(basename "$repo") already has the series in ${dir#"$ROOT"/}"; return 0
  fi
  [ "$(git -C "$repo" rev-parse HEAD)" = "$base" ] \
    || die "$repo is neither its pin nor its pin plus ${dir#"$ROOT"/}; scripts/sync-sources.sh moves it to the current patches"
  if [ "$(worktree_tree "$repo")" = "$want" ]; then
    adopt=1
  elif [ -n "$(git -C "$repo" status --porcelain)" ]; then
    die "$repo has changes on its pin that are not ${dir#"$ROOT"/}; scripts/sync-sources.sh moves it to the current patches"
  fi
  git -C "$repo" update-ref refs/kitsune/base "$base"
  msg="$(mktemp)" idx="$(mktemp)"
  rm -f "$idx"
  GIT_INDEX_FILE="$idx" git -C "$repo" read-tree "$base"
  parent="$base"
  for p in $(series_patches "$dir"); do
    GIT_INDEX_FILE="$idx" git -C "$repo" apply --cached --whitespace=nowarn "$p" \
      || die "$(basename "$p") does not apply to $repo"
    awk '/^---$/ || /^diff --git / { exit } { print }' "$p" | git stripspace > "$msg"
    [ -s "$msg" ] || basename "$p" .patch > "$msg"
    parent="$(GIT_AUTHOR_NAME=Kitsune GIT_AUTHOR_EMAIL=kitsune@localhost GIT_AUTHOR_DATE='@0 +0000' \
      GIT_COMMITTER_NAME=Kitsune GIT_COMMITTER_EMAIL=kitsune@localhost GIT_COMMITTER_DATE='@0 +0000' \
      git -C "$repo" commit-tree "$(GIT_INDEX_FILE="$idx" git -C "$repo" write-tree)" -p "$parent" -F "$msg")"
    n=$((n + 1))
  done
  rm -f "$msg" "$idx"
  if [ "$adopt" = 1 ]; then
    git -C "$repo" reset -q "$parent"
    log "recorded the $n patches in ${dir#"$ROOT"/} as commits in $(basename "$repo"); its files are unchanged"
  else
    git -C "$repo" reset -q --hard "$parent"
    log "applied $n patches from ${dir#"$ROOT"/} to $(basename "$repo")"
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

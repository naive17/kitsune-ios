#!/usr/bin/env bash
# From a fresh clone to an app ready to install: checks Xcode, installs the
# Homebrew packages, fetches the toolchains and the pinned sources, builds the
# Windows and iOS halves and stages the runtime the app bundles.
#
#   scripts/setup.sh               run every step that is not done yet
#   scripts/setup.sh --toolchain   only the toolchains and sources
#   scripts/setup.sh --from STEP   redo STEP and every step after it
#   scripts/setup.sh --list        the steps, and which ones would run
#   scripts/setup.sh --check       check Xcode and Homebrew only
#
# A step is done when its output exists and it last succeeded with the same
# script and pins.env. The toolchain steps are independent; the build steps are
# a chain, so once one runs, every later one runs too. Each step's log is in
# build/setup/. After setup, the numbered scripts rebuild single parts
# (docs/building.md).
source "$(dirname "$0")/common.sh"
cd "$ROOT"

STAMPS="$BUILD/setup"
BREW_PACKAGES="bison meson ninja pkgconf cmake freetype xcodegen glslang jq node"
FREE_GB="${SETUP_FREE_GB:-16}"

NAMES=() KINDS=() OUTPUTS=() COMMANDS=()
step() { NAMES+=("$1"); KINDS+=("$2"); OUTPUTS+=("$3"); COMMANDS+=("$4"); }

step llvm-mingw   toolchain "toolchains/llvm-mingw-$LLVM_MINGW_VER/bin/clang"  "bash scripts/01-toolchain.sh"
step sources      toolchain "third_party/vkd3d-proton/.git"                     "bash scripts/02-fetch.sh"
step llvm15-macos toolchain "toolchains/llvm15-macos/lib/libLLVMCore.a"         "TARGET=macos bash scripts/03-llvm15.sh"
step llvm15-ios   toolchain "toolchains/llvm15-ios/lib/libLLVMCore.a"           "TARGET=ios bash scripts/03-llvm15.sh"
step freetype     toolchain "out/freetype-ios/lib/libfreetype.a"                "bash scripts/04-freetype.sh"
step gnutls       toolchain "out/gnutls-ios/lib/libgnutls.30.dylib"             "bash scripts/05-gnutls-ios.sh"
step fex          build "out/fex/libarm64ecfex.dll"                             "bash scripts/06-fex-arm64ec.sh"
step wine-macos   build "build/wine-macos/tools/widl/widl"                      "bash scripts/07-wine-macos.sh"
step dxvk         build "out/dxvk-arm64ec/d3d9.dll"                             "bash scripts/08-dxvk.sh"
step vkd3d        build "out/vkd3d-arm64ec/d3d12.dll"                           "bash scripts/09-vkd3d.sh"
step dxmt         build "out/dxmt-arm64ec/d3d11.dll"                            "bash scripts/10-dxmt.sh"
step wine-ios     build "out/ios-unix/winecoreaudio.so"                         "bash scripts/11-wine-ios.sh"
step prefix       build "out/prefix/aarch64-windows/PROVENANCE.txt"             "bash scripts/12-stage-prefix.sh"
step wine-tree    build "out/wine-tree/lib/wine/aarch64-windows/ntdll.dll"      "bash scripts/13-stage-wine-tree.sh"
step wine-core    build "out/wine-core/lib/wine/aarch64-windows"                "python3 scripts/14-core-tree.py"
step dxmt-ios     build "out/ios-unix/winemetal.so"                             "bash scripts/15-dxmt-ios.sh"
step harness      build "build/ioswine-host"                                    "bash scripts/16-host-harness.sh"
step template     build "out/wine-core/prefix-template/system.reg"              "bash scripts/17-prefix-template.sh"
step tree-version build "out/wine-core/TREE_VERSION"                            "bash scripts/18-stamp-tree.sh"
step runtime      build ".deploy/runtime/lib/wine/aarch64-unix/winecoreaudio.so" "bash scripts/19-stage-runtime.sh"

# The command, the scripts it runs and the pins.
fingerprint() {
  local f
  { printf '%s\n' "$1"
    for f in $(printf '%s\n' "$1" | grep -o 'scripts/[^ ]*'); do cat "$f"; done
    cat pins.env
  } | shasum -a 256 | cut -d' ' -f1
}

is_done() {
  [ -e "${OUTPUTS[$1]}" ] &&
    [ "$(cat "$STAMPS/${NAMES[$1]}" 2>/dev/null)" = "$(fingerprint "${COMMANDS[$1]}")" ]
}

check_host() {
  [ "$(uname -sm)" = "Darwin arm64" ] || die "needs macOS on Apple silicon"
  [ -n "${DEVELOPER_DIR:-}" ] || die "no Xcode with the iPhoneOS SDK found. Install Xcode from the \
Mac App Store or developer.apple.com; one outside /Applications, ~/Downloads and /Volumes needs \
export DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer"
  log "Xcode: $DEVELOPER_DIR ($(xcodebuild -version | head -1))"
  xcodebuild -license check >/dev/null 2>&1 \
    || die "accept the Xcode license: sudo DEVELOPER_DIR=$DEVELOPER_DIR xcodebuild -license accept"
  xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1 \
    || die "finish Xcode's first launch: sudo DEVELOPER_DIR=$DEVELOPER_DIR xcodebuild -runFirstLaunch"
  xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 || die "$DEVELOPER_DIR has no iPhoneOS SDK"
  if ! xcrun --sdk iphoneos metal --version >/dev/null 2>&1; then
    log "downloading the Metal toolchain"
    xcodebuild -downloadComponent MetalToolchain
    xcrun --sdk iphoneos metal --version >/dev/null 2>&1 || die "the Metal toolchain is still missing"
  fi

  command -v brew >/dev/null || die "Homebrew is required: https://brew.sh"
  local pkg missing=""
  for pkg in $BREW_PACKAGES; do
    brew list --formula "$pkg" >/dev/null 2>&1 || missing="$missing $pkg"
  done
  if [ -n "$missing" ]; then
    log "brew install$missing"
    # shellcheck disable=SC2086
    brew install $missing
  fi
  # Apple ships bison 2.3; Wine's parsers need 3.0 or later.
  case "$(bison --version | head -1 | awk '{print $NF}')" in
    3.*|4.*) ;;
    *) die "bison is older than 3.0: PATH picks up /usr/bin/bison" ;;
  esac
  log "host ok"
}

# The commit-msg hook (CONTRIBUTING.md); CI has no use for it.
install_hooks() {
  [ -z "${CI:-}" ] && [ -f package.json ] || return 0
  [ -d node_modules/husky ] && [ "$(git config --get core.hooksPath)" = .husky/_ ] && return 0
  log "installing the git hooks (npm install)"
  npm install --no-audit --no-fund >/dev/null || warn "npm install failed; commits are not checked"
}

mode=all from=""
case "${1:-}" in
  "") ;;
  --toolchain) mode=toolchain ;;
  --list) mode=list ;;
  --check) check_host; install_hooks; exit 0 ;;
  --from)
    from="${2:-}"
    case " ${NAMES[*]} " in
      *" $from "*) ;;
      *) die "--from takes a step name: ${NAMES[*]}" ;;
    esac
    ;;
  -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "unknown option $1 (see --help)" ;;
esac

# Decide which steps run.
RUN=() pending=0 chain=0 forced=0
for i in "${!NAMES[@]}"; do
  [ "${NAMES[i]}" = "$from" ] && forced=1
  RUN[i]=0
  [ "$mode" = toolchain ] && [ "${KINDS[i]}" = build ] && continue
  if [ "$forced" = 1 ] || { [ "${KINDS[i]}" = build ] && [ "$chain" = 1 ]; } || ! is_done "$i"; then
    RUN[i]=1; chain=1; pending=$((pending + 1))
  fi
done

if [ "$mode" = list ]; then
  for i in "${!NAMES[@]}"; do
    if [ "${RUN[i]}" = 1 ]; then state=run; else state=done; fi
    printf '  %-5s %-13s %s\n' "$state" "${NAMES[i]}" "${COMMANDS[i]}"
  done
  exit 0
fi

check_host
install_hooks
if [ "$pending" = 0 ]; then
  log "nothing to do; scripts/setup.sh --from STEP redoes a step"
else
  # A fresh clone needs the space for everything; a partial setup has used some of it.
  if [ ! -d third_party/wine ]; then
    free="$(df -g "$ROOT" | tail -1 | awk '{print $4}')"
    [ "$free" -ge "$FREE_GB" ] \
      || die "a full setup needs about ${FREE_GB} GB free, have ${free} GB (SETUP_FREE_GB overrides)"
  fi
  mkdir -p "$STAMPS"
  started=$SECONDS n=0
  for i in "${!NAMES[@]}"; do
    [ "${RUN[i]}" = 1 ] || continue
    n=$((n + 1)) name="${NAMES[i]}" t=$SECONDS
    log "[$n/$pending] $name: ${COMMANDS[i]}"
    rm -f "$STAMPS/$name"
    (eval "${COMMANDS[i]}") 2>&1 | tee "$STAMPS/$name.log" \
      || die "$name failed; log: build/setup/$name.log. Rerun scripts/setup.sh to resume."
    [ -e "${OUTPUTS[i]}" ] || die "$name finished without ${OUTPUTS[i]}; log: build/setup/$name.log"
    fingerprint "${COMMANDS[i]}" > "$STAMPS/$name"
    log "$name done in $(( (SECONDS - t) / 60 )) min"
  done
  log "setup finished in $(( (SECONDS - started) / 60 )) min; $(df -g "$ROOT" | tail -1 | awk '{print $4}') GB free"
fi

if [ "$mode" = toolchain ]; then
  log "toolchains and sources ready; scripts/setup.sh builds the rest"
else
  log "next: scripts/app.sh install --full on a phone without a Wine tree, scripts/app.sh install after that (docs/device.md)"
fi

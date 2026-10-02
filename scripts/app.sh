#!/usr/bin/env bash
# Build, sign and install the iOS app.
#
#   scripts/app.sh build [--full]     thin update (default) or full bundle with the Wine tree
#   scripts/app.sh install [--full]   build, then install on the paired iPhone (UDID=... picks one)
#   scripts/app.sh sign-check         report which Apple Development identity the phone accepts
#   scripts/app.sh ipa [file.ipa]     full bundle packaged for sideloading (build/Kitsune-<version>.ipa)
#
# The thin build reuses the staged runtime in .deploy/runtime; the full
# build and the IPA need out/wine-core.
source "$(dirname "$0")/common.sh"
cd "$ROOT"
APP=build/xc-out/Kitsune.app
OUT=build/xc-out

# xcbuild <thin: 0|1> [xcodebuild arguments]: builds the app into $OUT.
# KITSUNE_TEAM and KITSUNE_BUNDLE_ID (local.env) replace the spec's team and id.
xcbuild() {
  local thin=$1 signing=(); shift
  [ -n "${KITSUNE_TEAM:-}" ] && signing+=("DEVELOPMENT_TEAM=$KITSUNE_TEAM")
  [ -n "${KITSUNE_BUNDLE_ID:-}" ] && signing+=("PRODUCT_BUNDLE_IDENTIFIER=$KITSUNE_BUNDLE_ID")
  xcodegen generate --spec kitsune-device.yml --project . >/dev/null
  KITSUNE_THIN_UPDATE=$thin xcodebuild -project kitsune-device.xcodeproj -target kitsune-device \
    -sdk iphoneos -configuration Release CONFIGURATION_BUILD_DIR="$PWD/$OUT" \
    GCC_SYMBOLS_PRIVATE_EXTERN=NO STRIP_INSTALLED_PRODUCT=NO ${signing[@]+"${signing[@]}"} "$@" build \
    | grep -E "error:|warning: (unused|deprecated)|BUILD (SUCCEEDED|FAILED)"
}

build() {
  local thin=1
  [ "${1:-}" = "--full" ] && thin=0
  if [ -f out/ios-unix/winemetal.so ]; then bash scripts/19-stage-runtime.sh; fi
  test -f .deploy/runtime/lib/wine/aarch64-unix/winecoreaudio.so \
    || { echo "no staged runtime: run the unix-side build, then scripts/19-stage-runtime.sh" >&2; exit 1; }
  xcbuild "$thin" -allowProvisioningUpdates || true
  test -x "$APP/Kitsune"
  # Xcode skips CodeSign on an incremental build even though the post-build
  # script replaced bundle files; re-seal with the identity and entitlements
  # of the existing signature.
  if ! codesign --verify --deep --strict "$APP" 2>/dev/null; then resign; fi
  codesign --verify --deep --strict "$APP"
  echo "built $APP"
}

resign() {
  local tmp id
  tmp=$(mktemp -d)
  codesign -d --extract-certificates="$tmp/cs" "$APP" 2>/dev/null || { echo "no signature to reuse" >&2; exit 1; }
  id=$(openssl x509 -inform DER -in "$tmp/cs0" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')
  codesign -d --entitlements :- "$APP" > "$tmp/entitlements.plist" 2>/dev/null
  find "$APP" \( -name '*.so' -o -name '*.dylib' \) -exec codesign --force --sign "$id" --timestamp=none {} \;
  codesign --force --sign "$id" --timestamp=none --entitlements "$tmp/entitlements.plist" --generate-entitlement-der "$APP"
  rm -rf "$tmp"
}

# An IPA for SideStore, AltStore, Sideloadly and the like, which re-sign it with
# the installing user's certificate. It is ad-hoc signed with the app's
# entitlements so that they travel with it, and built in its own directory so
# the development-signed app in build/xc-out stays as it is. KITSUNE_VERSION
# sets CFBundleShortVersionString, and the version names the file.
ipa() {
  local dest="${1:-}" OUT=build/xc-ipa APP=build/xc-ipa/Kitsune.app stage
  test -f out/wine-core/TREE_VERSION || { echo "no out/wine-core: run scripts/setup.sh" >&2; exit 1; }
  rm -rf "$APP"
  # Its own build database too: Xcode deletes another build directory's app as
  # a stale output when two builds of the target share one.
  xcbuild 0 CODE_SIGNING_ALLOWED=NO SYMROOT="$PWD/build/xc-ipa-work" OBJROOT="$PWD/build/xc-ipa-work" \
    || { echo "xcodebuild failed" >&2; exit 1; }
  test -x "$APP/Kitsune"
  if [ -n "${KITSUNE_VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $KITSUNE_VERSION" "$APP/Info.plist"
  fi
  [ -n "$dest" ] || dest="build/Kitsune-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist").ipa"
  find "$APP" \( -name '*.so' -o -name '*.dylib' \) -exec codesign --force --sign - --timestamp=none {} \;
  codesign --force --sign - --timestamp=none --entitlements src/ios/kitsune.entitlements \
    --generate-entitlement-der "$APP"
  codesign --verify --deep --strict "$APP"
  mkdir -p "$(dirname "$dest")"
  dest="$(cd "$(dirname "$dest")" && pwd)/$(basename "$dest")"
  stage=$(mktemp -d)
  mkdir "$stage/Payload"
  ditto "$APP" "$stage/Payload/$(basename "$APP")"
  rm -f "$dest"
  (cd "$stage" && zip -qry "$dest" Payload)
  rm -rf "$stage"
  echo "packaged $dest ($(du -h "$dest" | cut -f1))"
}

install() {
  local udid
  udid=$(phone_udid)
  build "${1:-}"
  xcrun devicectl device install app --device "$udid" "$PWD/$APP" --timeout 300
}

case "${1:-build}" in
  build) build "${2:-}";;
  install) install "${2:-}";;
  sign-check) bash scripts/dev/signing-identity.sh;;
  ipa) ipa "${2:-}";;
  *) echo "usage: $0 build [--full] | install [--full] | sign-check | ipa [file.ipa]" >&2; exit 2;;
esac

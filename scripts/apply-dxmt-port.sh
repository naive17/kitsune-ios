#!/usr/bin/env bash
# Put third_party/dxmt at the port's base commit and apply the full patch.
# Idempotent. See patches/dxmt/ios-dxmt-full-vs-upstream.README.
source "$(dirname "$0")/common.sh"

SRC="$THIRD_PARTY/dxmt"
P="$ROOT/patches/dxmt"
[ -d "$SRC/.git" ] || die "run 02-fetch.sh first"

case "$(git -C "$SRC" log -1 --format=%s)" in
  "ios-wine base"*) ;;
  *)
    [ "$(git -C "$SRC" rev-parse HEAD)" = "$DXMT_SHA" ] || die "dxmt is at $(git -C "$SRC" rev-parse --short HEAD), expected $DXMT_SHA or the ios-wine base commit"
    [ -z "$(git -C "$SRC" status --porcelain)" ] || die "dxmt has local changes; commit or discard them first"
    git -C "$SRC" apply "$P/0001-xcode27-metal-and-libcxx-fixes.patch"
    git -C "$SRC" apply "$P/0002-winemetal-ios-unix-half.patch"
    git -C "$SRC" add -A
    git -C "$SRC" -c user.name=ios-wine -c user.email=ios-wine@localhost commit -q -m "ios-wine base"
    log "dxmt base commit created"
    ;;
esac
if git -C "$SRC" apply --check --reverse "$P/ios-dxmt-full-vs-upstream.patch" 2>/dev/null; then
  log "dxmt port already applied"
else
  git -C "$SRC" apply "$P/ios-dxmt-full-vs-upstream.patch" || die "the DXMT port does not apply"
  log "dxmt port applied"
fi
git -C "$SRC" add -N src/winemetal/unix/bc_transcode.cpp src/winemetal/unix/etcpak src/dxmt/bcdec.h \
  src/dxmt/bcdec.README src/dxmt/dxmt_bc_decode.hpp 2>/dev/null || true

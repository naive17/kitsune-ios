#!/usr/bin/env bash
# Copy curl's Mozilla root store (MPL-2.0) and its notice into a directory,
# fetching it into .deploy/trust first and checking it against a pinned SHA-256;
# never fall back to an unverified bundle.
# Usage: bash scripts/lib/stage-ca-bundle.sh <existing destination directory>
set -euo pipefail
test "$#" = 1 && test -d "$1" || {
  echo 'usage: stage-ca-bundle.sh <existing destination directory>' >&2; exit 1;
}
trust_root="$(cd "$(dirname "$0")/../.." && pwd)"
trust_cache="$trust_root/.deploy/trust"
trust_bundle="$trust_cache/cacert.pem"
trust_sha=f66dff1bdf8f96060b8177976f8b7d9254bc89bc4db933d769f7384d28480bc9
trust_url=https://curl.se/ca/cacert-2026-08-13.pem
valid_bundle() {
  test -f "$1" && test "$(shasum -a 256 "$1" | awk '{print $1}')" = "$trust_sha"
}
if ! valid_bundle "$trust_bundle"; then
  mkdir -p "$trust_cache"
  trust_scratch="$(mktemp -d "$trust_cache/download.XXXXXX")"
  trap 'rm -f "$trust_scratch/cacert.pem"; rmdir "$trust_scratch"' EXIT
  curl --fail --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 15 --max-time 60 "$trust_url" -o "$trust_scratch/cacert.pem"
  valid_bundle "$trust_scratch/cacert.pem" || {
    echo 'CA bundle hash mismatch; refusing to package unverified trust material' >&2
    exit 1
  }
  mv "$trust_scratch/cacert.pem" "$trust_bundle"
fi
cp "$trust_bundle" "$1/cacert.pem"
cp "$trust_root/assets/ca-bundle-NOTICE.txt" "$1/ca-bundle-NOTICE.txt"
echo "CA bundle verified: 2026-08-13 / $trust_sha"

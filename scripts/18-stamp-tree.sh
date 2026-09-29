#!/usr/bin/env bash
# Write out/wine-core/TREE_VERSION from the tree's content, so the app can
# tell an installed tree from the one it bundles.
set -euo pipefail
cd "$(dirname "$0")/.."
test -d out/wine-core || { echo "out/wine-core missing; run 13-stage-wine-tree.sh and 14-core-tree.py" >&2; exit 1; }
stamp=$(cd out/wine-core && find . -type f ! -name TREE_VERSION -exec shasum {} \; | sort | shasum | cut -c1-12)
printf '%s' "$stamp" > out/wine-core/TREE_VERSION
echo "tree stamp: $stamp"

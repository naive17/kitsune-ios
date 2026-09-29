#!/usr/bin/env bash
# Make room on a GitHub-hosted macOS runner, which guarantees only 14 GB: the
# build needs none of the simulators, other Xcodes, Android or .NET SDKs.
# A self-hosted runner skips this (RUNNER_ENVIRONMENT is not github-hosted).
set -uo pipefail
[ "${RUNNER_ENVIRONMENT:-}" = github-hosted ] || { echo "not a GitHub-hosted runner; skipped"; exit 0; }
df -h / | tail -1
keep="$(cd "$(xcode-select -p)/../.." && pwd -P)"
case "$keep" in
  *.app)
    for x in /Applications/Xcode*.app; do
      [ "$(cd "$x" && pwd -P)" = "$keep" ] || sudo rm -rf "$x"
    done ;;
  *) echo "the selected developer dir is not an Xcode ($keep); keeping every Xcode" ;;
esac
xcrun simctl runtime delete all >/dev/null 2>&1 || true
sudo rm -rf "$HOME/Library/Android" /usr/local/share/dotnet "$HOME/.dotnet" \
  "$HOME/hostedtoolcache/CodeQL" "$HOME/hostedtoolcache/go" "$HOME/hostedtoolcache/PyPy"
df -h / | tail -1

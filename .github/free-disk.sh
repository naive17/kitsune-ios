#!/usr/bin/env bash
# Make room on a GitHub-hosted macOS runner when it is short of it: the build
# needs about 16 GB and none of the simulators, other Xcodes, Android or .NET
# SDKs. macos-26 runners start with about 96 GB free, so this usually only
# checks. A self-hosted runner skips it (RUNNER_ENVIRONMENT is not github-hosted).
set -uo pipefail
[ "${RUNNER_ENVIRONMENT:-}" = github-hosted ] || { echo "not a GitHub-hosted runner; skipped"; exit 0; }
df -h / | tail -1
free="$(df -g / | awk 'NR == 2 { print $4 }')"
[ "${free:-0}" -ge 30 ] && { echo "${free} GB free; nothing to delete"; exit 0; }
keep="$(cd "$(xcode-select -p)/../.." && pwd -P)"
case "$keep" in
  *.app)
    for x in /Applications/Xcode*.app; do
      # Some image entries are links to Xcodes that are not installed.
      [ "$(cd "$x" 2>/dev/null && pwd -P)" = "$keep" ] || sudo rm -rf "$x"
    done ;;
  *) echo "the selected developer dir is not an Xcode ($keep); keeping every Xcode" ;;
esac
xcrun simctl runtime delete all >/dev/null 2>&1 || true
sudo rm -rf "$HOME/Library/Android" /usr/local/share/dotnet "$HOME/.dotnet" \
  "$HOME/hostedtoolcache/CodeQL" "$HOME/hostedtoolcache/go" "$HOME/hostedtoolcache/PyPy"
df -h / | tail -1

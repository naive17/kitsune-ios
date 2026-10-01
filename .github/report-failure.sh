#!/usr/bin/env bash
# Print the end of a failed step's log as an error annotation. The run page
# shows the full log only to the repository's admins; annotations are public,
# so the reason for a failure can be read without signing in.
#   .github/report-failure.sh <log> [title]
log="${1:?usage: report-failure.sh <log> [title]}" title="${2:-failed}"
[ -s "$log" ] || { echo "::error title=$title::no log at $log"; exit 0; }
# Workflow commands end at a newline; %, CR and LF are escaped.
msg="$(tail -n 60 "$log" | sed 's/\x1b\[[0-9;]*m//g' | sed 's/%/%25/g' | awk '{ printf "%s%%0A", $0 }' | tr -d '\r')"
echo "::error title=$title::$msg"

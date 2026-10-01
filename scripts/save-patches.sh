#!/usr/bin/env bash
# Records the Wine and DXMT checkouts as the port's patches.
#
# third_party/wine and third_party/dxmt each hold their series (patches/wine,
# patches/dxmt) as commits on their pin (apply_series in common.sh). Unsaved
# edits are folded into the commit that owns each file: the one patch that
# changes it, or, for a file no patch changes yet, the one patch that changes
# files in its directory. Then every commit is written out as
# patches/<name>/NNNN-subject.patch, its message first. A new patch is a new
# commit in the checkout (git -C third_party/<name> commit); it is written out
# in its place, and wants a line in patches/<name>/README.
source "$(dirname "$0")/common.sh"

# save_series <name>: third_party/<name> to patches/<name>.
save_series() {
W="$THIRD_PARTY/$1"
SERIES="$ROOT/patches/$1"
base="$(git -C "$W" rev-parse -q --verify refs/kitsune/base)" \
  || die "third_party/$1 does not hold the series as commits; scripts/sync-sources.sh sets it up"
[ -z "$(git -C "$W" rev-list --merges "$base..HEAD")" ] \
  || die "third_party/$1 has merges on its pin; the series must be a straight line of commits"

# The series' commits that touch a path, leaving out pending fixup!, squash!
# and amend! commits.
touching() {
  git -C "$W" log --format='%H %s' "$base..HEAD" -- "$1" |
    { grep -Ev '^[0-9a-f]+ (fixup|squash|amend)! ' || true; } | cut -d' ' -f1
}

# owner <path>: the one commit that owns it, or nothing.
owner() {
  local c
  c="$(touching "$1")"
  if [ -z "$c" ] && [ "$(dirname "$1")" != . ]; then c="$(touching "$(dirname "$1")")"; fi
  [ "$(printf '%s\n' "$c" | grep -c .)" = 1 ] && echo "$c"
  return 0
}

subject() { git -C "$W" log -1 --format=%s "$1"; }

# Unsaved edits, listed through a scratch index so that the checkout's own is
# left alone until every file has an owner.
idx="$(mktemp)"
cp "$(git -C "$W" rev-parse --absolute-git-dir)/index" "$idx"
GIT_INDEX_FILE="$idx" git -C "$W" add -A
edits="$(GIT_INDEX_FILE="$idx" git -C "$W" diff --cached --name-only --no-renames HEAD)"
rm -f "$idx"

if [ -n "$edits" ]; then
  plan="" unowned=""
  for f in $edits; do
    o="$(owner "$f")"
    if [ -n "$o" ]; then plan="$plan$o $f"$'\n'; else unowned="$unowned $f"; fi
  done
  if [ -n "$unowned" ]; then
    for f in $unowned; do
      warn "$f: no single patch owns it. Patches that change $(dirname "$f"):"
      for c in $(touching "$(dirname "$f")"); do warn "    ${c:0:12} $(subject "$c")"; done
    done
    die "commit these yourself, then rerun: git -C third_party/$1 add <files> && git -C third_party/$1 commit --fixup=<commit> (or commit -m \"<subject>\" for a new patch). Nothing was changed."
  fi
  git -C "$W" reset -q
  for o in $(printf '%s' "$plan" | cut -d' ' -f1 | sort -u); do
    # shellcheck disable=SC2046
    git -C "$W" add -A -- $(printf '%s' "$plan" | awk -v o="$o" '$1 == o { print $2 }')
    git -C "$W" -c commit.gpgsign=false commit -q --no-verify --fixup="$o"
    log "$(printf '%s' "$plan" | awk -v o="$o" '$1 == o { printf "%s ", $2 }')-> $(subject "$o")"
  done
fi

# Read the whole list: with pipefail, grep -q stopping at the first match --
# the newest commit, so the first line -- left git log to die of SIGPIPE and
# the test false, and the fixup was written out as a patch of its own.
pending="$(git -C "$W" log --format=%s "$base..HEAD" | { grep -E '^(fixup|squash|amend)! ' || true; })"
if [ -n "$pending" ]; then
  GIT_SEQUENCE_EDITOR=: GIT_EDITOR=: git -C "$W" -c commit.gpgsign=false rebase -q -i --autosquash "$base" \
    || die "the rebase that folds edits into the series stopped; finish it in third_party/$1 (git status there), then rerun"
fi

# Write the series out. Fixed diff options keep the files the same whatever
# the local git configuration.
rm -f "$SERIES"/[0-9][0-9][0-9][0-9]-*.patch
n=0
for c in $(git -C "$W" rev-list --reverse "$base..HEAD"); do
  n=$((n + 1))
  slug="$(subject "$c" | tr -d "'" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-//; s/-$//')"
  # At most 52 characters, cut between words.
  [ "${#slug}" -le 52 ] || slug="$(printf '%s' "$slug" | cut -c1-53 | sed -E 's/-[^-]*$//')"
  {
    git -C "$W" log -1 --format=%B "$c" | git stripspace
    echo ---
    git -C "$W" diff --no-ext-diff --no-color --no-renames --full-index --diff-algorithm=histogram \
      --unified=3 --src-prefix=a/ --dst-prefix=b/ "$c^" "$c"
  } > "$SERIES/$(printf '%04d' "$n")-$slug.patch"
done
[ "$(series_tree "$W" "$base" "$SERIES")" = "$(git -C "$W" rev-parse 'HEAD^{tree}')" ] \
  || die "the written series does not reproduce third_party/$1's HEAD"
for p in $(series_patches "$SERIES"); do
  grep -q "^$(basename "$p" | cut -c1-4) " "$SERIES/README" 2>/dev/null \
    || warn "patches/$1/README has no line for $(basename "$p")"
done
log "wrote $n patches to patches/$1"

}

save_series wine
save_series dxmt
git -C "$ROOT" status --short -- patches/wine patches/dxmt

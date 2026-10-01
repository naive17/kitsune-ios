#!/usr/bin/env bash
# Brings the patched checkouts in third_party/ in line with patches/, as after
# a pull that changed a port: each checkout that is not at its pin plus the
# current patches is reset to the pin and patched again.
#
#   scripts/sync-sources.sh              sync every checkout that needs it
#   scripts/sync-sources.sh --check      only report; exits 1 when one needs it
#   scripts/sync-sources.sh --discard    also reset checkouts with unsaved edits
#   scripts/sync-sources.sh wine fex     only these checkouts (and their submodules)
#
# A checkout is reset only when its files are exactly its pin plus the patches
# of some commit, or the bare pin, so nothing is lost that git does not have.
# The stacks are read from the scripts that apply them (02-fetch.sh, 06, 08
# and 09, and apply-dxmt-port.sh before DXMT's port became a series) as they
# were at each commit. A checkout
# with edits that no commit has is left alone unless --discard is given; the
# edits are saved to build/source-backups/ first, and
# `git -C <checkout> apply -3 <saved patch>` carries them onto the new patches.
source "$(dirname "$0")/common.sh"
cd "$ROOT"

check=0 discard=0 only=""
for a in "$@"; do
  case "$a" in
    --check) check=1 ;;
    --discard) discard=1 ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option $a (see --help)" ;;
    *) a="${a%/}"; only="$only third_party/${a#third_party/}" ;;
  esac
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
touch "$TMP/expected"

# The scripts that apply patches with apply_patch or apply_series, and the
# checkout that their $SRC or $FEX_SRC names.
STACK_SCRIPTS="02-fetch.sh: 06-fex-arm64ec.sh:third_party/fex 08-dxvk.sh:third_party/dxvk
  09-vkd3d.sh:third_party/vkd3d-proton"

# show <rev> <path>: a file as of <rev>, or the working copy for rev "work".
show() {
  if [ "$1" = work ]; then cat "$2" 2>/dev/null || true
  else git show "$1:$2" 2>/dev/null || true; fi
}

# series_at <rev> <dir>: the patches of a series as of <rev>, in order.
series_at() {
  if [ "$1" = work ]; then series_patches "$2" 2>/dev/null || true
  else git ls-tree --name-only "$1" "$2/" | { grep -E '/[0-9]{4}-[^/]*\.patch$' || true; } | sort; fi
}

# stacks <rev>: "<checkout> <patch>" per line, in the order the build applies
# them. A series' checkout and directory also go to $TMP/series.<rev>.
stacks() {
  local rev="$1" entry script src fn tree path
  touch "$TMP/series.$rev"
  for entry in $STACK_SCRIPTS; do
    script="${entry%%:*}" src="${entry#*:}"
    # Joins continued lines, keeps the calls, resolves the checkout.
    show "$rev" "scripts/$script" |
      sed -e ':a' -e '/\\$/N' -e 's/\\\n[[:space:]]*//' -e 'ta' |
      sed -nE 's#^[[:space:]]*(apply_patch|apply_series) "([^"]*)" "\$ROOT/([^"]*)".*#\1 \2 \3#p' |
      sed -e 's# \$THIRD_PARTY# third_party#' -e "s# \\\$FEX_SRC# $src#" -e "s# \\\$SRC# $src#" |
      while read -r fn tree path; do
        if [ "$fn" = apply_patch ]; then
          echo "$tree $path"
        else
          echo "$tree $path" >> "$TMP/series.$rev"
          series_at "$rev" "$path" | sed "s#^#$tree #"
        fi
      done
  done
  # Before DXMT's port was a series, apply-dxmt-port.sh applied 0001 and 0002
  # (its base commit), then the full patch; the stack is the pin plus all three.
  show "$rev" scripts/apply-dxmt-port.sh | { grep -o '"\$P/[^"]*\.patch"' || true; } |
    sed 's|^"\$P/\(.*\)"$|third_party/dxmt patches/dxmt/\1|' | awk '!seen[$0]++'
}

stack_of() { awk -v t="$1" '$1 == t { print $2 }' "$TMP/stack.$2"; }

# series_dir <checkout>: its patch series' directory, when the current scripts
# apply one to it.
series_dir() { awk -v t="$1" '$1 == t { print $2 }' "$TMP/series.work"; }

# The commit a checkout's stack applies to: under a series' commits, or under
# the base commit that apply-dxmt-port.sh used to make ("ios-wine base" before the
# rename).
base_of() {
  if [ "$1" = third_party/dxmt ] &&
     git -C "$1" log -1 --format=%s | grep -Eq '^(Kitsune|ios-wine) base$'; then
    git -C "$1" rev-parse HEAD^
  else
    series_base "$1"
  fi
}

# pin <checkout>: "<url> <sha>" for the checkouts that 02-fetch.sh clones.
pin() {
  case "$1" in
    third_party/wine) echo "$WINE_URL $WINE_SHA" ;;
    third_party/fex) echo "$FEX_URL $FEX_SHA" ;;
    third_party/dxvk) echo "$DXVK_URL $DXVK_SHA" ;;
    third_party/dxmt) echo "$DXMT_URL $DXMT_SHA" ;;
    third_party/vkd3d-proton) echo "$VKD3D_URL $VKD3D_SHA" ;;
  esac
}

# current <checkout>: the tree id of its files as they are on disk.
current() { worktree_tree "$1"; }

# expected <checkout> <base> <rev>: the tree id of <base> with the checkout's
# stack as of <rev> ("pristine": none), or nothing when a patch is missing or
# does not apply. Cached by the patches' contents; many commits share them.
expected() {
  local tree="$1" base="$2" rev="$3" patches="" blobs="" p b key idx="$TMP/index.expected" id
  if [ "$rev" = pristine ]; then git -C "$tree" rev-parse "$base^{tree}"; return; fi
  patches="$(stack_of "$tree" "$rev")"
  for p in $patches; do
    if [ "$rev" = work ]; then b="$(git hash-object "$p" 2>/dev/null)" || return 0
    else b="$(git rev-parse -q --verify "$rev:$p")" || return 0; fi
    blobs="$blobs $b"
  done
  key="$(printf '%s %s%s' "$tree" "$base" "$blobs" | shasum | cut -d' ' -f1)"
  id="$(awk -v k="$key" '$1 == k { print $2 }' "$TMP/expected")"
  if [ -z "$id" ]; then
    id=-
    rm -f "$idx"
    GIT_INDEX_FILE="$idx" git -C "$tree" read-tree "$base"
    for p in $patches; do
      show "$rev" "$p" > "$TMP/patch"
      GIT_INDEX_FILE="$idx" git -C "$tree" apply --cached --whitespace=nowarn "$TMP/patch" 2>/dev/null ||
        { echo "$key -" >> "$TMP/expected"; return 0; }
    done
    id="$(GIT_INDEX_FILE="$idx" git -C "$tree" write-tree)"
    echo "$key $id" >> "$TMP/expected"
  fi
  [ "$id" = - ] || echo "$id"
}

same() { git -C "$1" diff --quiet --ignore-submodules "$2" "$3"; }

# selected <checkout>: named on the command line, or inside one that is.
selected() {
  local o
  [ -n "$only" ] || return 0
  for o in $only; do case "$1" in "$o"|"$o"/*) return 0 ;; esac; done
  return 1
}

describe() {
  case "$1" in
    pristine) echo "the bare pin" ;;
    work) echo "the current patches" ;;
    *) git log -1 --format='%h (%s)' "$1" ;;
  esac
}

# The first setup.sh step that builds from each checkout; setup.sh runs its
# build steps in this order.
first_step() {
  case "$1" in
    third_party/fex*) echo "1 fex" ;;
    third_party/wine) echo "2 wine-macos" ;;
    third_party/dxvk*) echo "3 dxvk" ;;
    third_party/vkd3d-proton*) echo "4 vkd3d" ;;
    third_party/dxmt) echo "5 dxmt" ;;
  esac
}

# The candidates: the current patches, the bare pin, and the patches of every
# recent commit that changed a patch or a script that applies one.
REVS="$(git log --all --reflog --format=%H -n 40 -- patches scripts/apply-dxmt-port.sh \
  $(for e in $STACK_SCRIPTS; do echo "scripts/${e%%:*}"; done))"
for rev in work $REVS; do stacks "$rev" > "$TMP/stack.$rev"; done
for t in third_party/wine third_party/dxmt third_party/fex; do
  [ -n "$(stack_of "$t" work)" ] || die "found no patches for $t in the scripts; has the way they apply them changed?"
done

# Superprojects sort before their submodules.
TREES="$(cat "$TMP"/stack.* | awk '{ print $1 }' | sort -u)"

stale="" adopt="" edited="" broken=0
for tree in $TREES; do
  selected "$tree" || continue
  if [ ! -e "$tree/.git" ]; then
    warn "$tree: not checked out; scripts/02-fetch.sh fetches it"
    continue
  fi
  base="$(base_of "$tree")"
  cur="$(current "$tree")"
  read -r _ pinned <<<"$(pin "$tree")"
  moved=0
  [ -n "$pinned" ] && [ "$pinned" != "$base" ] && moved=1

  if [ "$moved" = 0 ]; then
    want="$(expected "$tree" "$base" work)"
    if [ -z "$want" ]; then
      warn "$tree: the current patches do not apply to its pin"
      broken=1
      continue
    fi
    if same "$tree" "$cur" "$want"; then
      # A series checkout also needs the series as its commits.
      if [ -n "$(series_dir "$tree")" ] && ! same "$tree" HEAD "$want"; then
        log "$tree: has the current patches, but not as commits"
        adopt="$adopt $tree"
      else
        log "$tree: up to date"
      fi
      continue
    fi
  fi

  match=""
  for c in pristine $REVS; do
    id="$(expected "$tree" "$base" "$c")"
    if [ -n "$id" ] && same "$tree" "$cur" "$id"; then match="$c"; break; fi
  done
  if [ -n "$match" ]; then
    how="has the patches of $(describe "$match")"
    [ "$match" = pristine ] && how="is at the bare pin"
    [ "$moved" = 1 ] && how="$how; pins.env moved it to ${pinned:0:12}"
    log "$tree: $how"
    stale="$stale $tree"
    continue
  fi

  # Edits that no commit has. Report them against the closest candidate.
  best="" bestn="" candidates="pristine $REVS"
  [ "$moved" = 1 ] || candidates="work $candidates"
  for c in $candidates; do
    id="$(expected "$tree" "$base" "$c")"
    [ -n "$id" ] || continue
    n="$(git -C "$tree" diff --name-only --ignore-submodules "$id" "$cur" | wc -l | tr -d ' ')"
    if [ -z "$bestn" ] || [ "$n" -lt "$bestn" ]; then best="$c" bestn="$n" bestid="$id"; fi
  done
  warn "$tree: $bestn file(s) differ from $(describe "$best"), and no commit has them:"
  git -C "$tree" diff --name-only --ignore-submodules "$bestid" "$cur" | head -10 | sed 's/^/      /' >&2
  [ "$bestn" -gt 10 ] && echo "      ... and $((bestn - 10)) more" >&2
  if [ "$check" = 0 ]; then
    git -C "$tree" diff --binary --full-index --ignore-submodules "$bestid" "$cur" > "$TMP/edits"
    mkdir -p "$BUILD/source-backups"
    saved="$BUILD/source-backups/$(echo "${tree#third_party/}" | tr / -)-$(shasum < "$TMP/edits" | cut -c1-12).patch"
    mv "$TMP/edits" "$saved"
    warn "  saved to $saved"
    warn "  carry them over after a sync: git -C $tree apply -3 $saved"
  fi
  edited="$edited $tree"
done

if [ "$check" = 1 ]; then
  [ -z "$stale$adopt$edited" ] && [ "$broken" = 0 ] && exit 0
  exit 1
fi

# Commits over files that are already right: nothing to rebuild.
for tree in $adopt; do
  drop_legacy_base "$ROOT/$tree"
  apply_series "$ROOT/$tree" "$ROOT/$(series_dir "$tree")"
done

todo="$stale"
if [ -n "$edited" ]; then
  if [ "$discard" = 1 ]; then
    todo="$todo $edited"
  else
    warn "left as they are:$edited (--discard resets them too; their edits are saved above)"
  fi
fi

step=""
for tree in $(printf '%s\n' $todo | sort); do
  log "$tree: resetting to the pin and applying the current patches"
  git -C "$tree" reset -q --hard "$(base_of "$tree")"
  git -C "$tree" clean -fdq
  read -r url pinned <<<"$(pin "$tree")"
  if [ -n "$pinned" ] && [ "$pinned" != "$(git -C "$tree" rev-parse HEAD)" ]; then
    pin_clone "$url" "$pinned" "$ROOT/$tree"
  fi
  series="$(series_dir "$tree")"
  if [ -n "$series" ]; then
    apply_series "$ROOT/$tree" "$ROOT/$series"
  else
    for p in $(stack_of "$tree" work); do apply_patch "$ROOT/$tree" "$ROOT/$p"; done
  fi
  want="$(expected "$tree" "$(base_of "$tree")" work)"
  [ -n "$want" ] && same "$tree" "$(current "$tree")" "$want" \
    || die "$tree does not match the current patches after the sync"
  [ -z "$series" ] || same "$tree" HEAD "$want" \
    || die "$tree does not hold the current patches as commits after the sync"
  s="$(first_step "$tree")"
  if [ -n "$s" ] && { [ -z "$step" ] || [ "${s%% *}" -lt "${step%% *}" ]; }; then step="$s"; fi
done

if [ -n "$step" ]; then
  # setup.sh's stamps cover its scripts and pins.env, not the patches.
  log "synced. next: scripts/setup.sh --from ${step#* } rebuilds everything from the changed sources"
elif [ -n "$adopt" ]; then
  log "synced; the files did not change, so nothing needs rebuilding"
elif [ -z "$edited" ] && [ "$broken" = 0 ]; then
  log "every checkout matches the current patches"
fi
[ -z "$edited" ] || [ "$discard" = 1 ] || exit 1
[ "$broken" = 0 ] || exit 1

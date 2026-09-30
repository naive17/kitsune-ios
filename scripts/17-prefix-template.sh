#!/usr/bin/env bash
# Build out/wine-core/prefix-template, the prefix the app installs on first
# launch instead of running wineboot --init on the phone. Requires
# build/kitsune-host and build/host-tree (16-host-harness.sh) and out/wine-core.
set -euo pipefail
source "$(dirname "$0")/common.sh"

CORE="$OUT/wine-core"
HOST="$ROOT/build/kitsune-host"
UNIX="$ROOT/build/host-tree"
DEST="$CORE/prefix-template"
WORK="$BUILD/prefix-template-work"

[ -x "$HOST" ] || die "no harness; run 16-host-harness.sh"
[ -d "$CORE/lib/wine/aarch64-windows" ] || die "no core tree; run 14-core-tree.py"
[ -d "$UNIX/lib/wine/aarch64-unix" ] || die "no unix halves; run 16-host-harness.sh"

# Reuse the cached template unless the tree changed. wineboot writes timestamps
# into the registry, so a fresh template on an unchanged tree would still change
# the tree stamp (18-stamp-tree.sh), and the app would install the whole tree
# again. The cache is in build/ because 14-core-tree.py recreates
# out/wine-core.
TREE_HASH=$( { find "$CORE/lib" "$CORE/share" -type f -exec shasum {} \; ; } \
             | sed "s|$CORE/||" | sort | shasum | cut -c1-16 )
# The hash covers only the tree, so the suffix must change whenever the prefix
# edits below change; otherwise an older cached template is reused.
CACHE="$BUILD/prefix-template-cache/$TREE_HASH-v2"

if [ -f "$CACHE/system.reg" ]; then
  rm -rf "$DEST"
  cp -R "$CACHE" "$DEST"
  log "prefix template: reused (tree $TREE_HASH unchanged)"
  exit 0
fi

rm -rf "$WORK" "$DEST"
mkdir -p "$WORK"

log "running wineboot --init against the shipping tree"
# set_home_dir() in ntdll/unix/loader.c turns $USER into the C:\users\<name>
# profile paths in system.reg, so it must match what the app sets
# (configure_environment() in src/ios/wine_boot.m).
USER=wine LOGNAME=wine \
KITSUNE_UNIX="$UNIX" KITSUNE_TREE="$CORE" KITSUNE_PREFIX="$WORK" \
  env WINEDEBUG=-all "$HOST" \
      "$CORE/lib/wine/aarch64-windows/wineboot.exe" --init \
  </dev/null >"$BUILD/prefix-template.log" 2>&1 \
  || { warn "wineboot failed; tail:"; tail -20 "$BUILD/prefix-template.log"; die "see $BUILD/prefix-template.log"; }

[ -f "$WORK/system.reg" ] || die "no system.reg; see $BUILD/prefix-template.log"

# FEX reads the CPU-feature keys to identify the host; without them it
# mis-decodes and fails in ways that look like translation bugs.
grep -q "CP 4030" "$WORK/system.reg" || die "prefix has no CPU-feature keys"

# Register mmdevapi's MMDeviceEnumerator class. This wineboot --init does not
# apply wine.inf's [AddReg] sections, and wine.inf does not register mmdevapi,
# so without it dsound's CoCreateInstance(CLSID_MMDeviceEnumerator) fails with
# REGDB_E_CLASSNOTREG and audio never initialises. system.reg keys are relative
# to REGISTRY\Machine (HKCR is Software\Classes); key timestamps are optional.
if ! grep -q "BCDE0395-E52F-467C-8E3D-C4579291692E" "$WORK/system.reg"; then
  cat >> "$WORK/system.reg" <<'REGEOF'

[Software\\Classes\\CLSID\\{BCDE0395-E52F-467C-8E3D-C4579291692E}]
@="MMDeviceEnumerator class"

[Software\\Classes\\CLSID\\{BCDE0395-E52F-467C-8E3D-C4579291692E}\\InprocServer32]
@="mmdevapi.dll"
"ThreadingModel"="Both"
REGEOF
fi
grep -q "BCDE0395-E52F-467C-8E3D-C4579291692E" "$WORK/system.reg" \
  || die "failed to register MMDeviceEnumerator class in prefix template"

# Populate Shell Folders and User Shell Folders, left empty for the same reason.
# Without them Steam cannot resolve shell folders and Steam Cloud save checks
# hang. str(2) is REG_EXPAND_SZ, so the values follow %USERPROFILE%.
if ! grep -q '"Personal"' "$WORK/user.reg"; then
  for key in "Shell Folders" "User Shell Folders"; do
    cat >> "$WORK/user.reg" <<REGEOF

[Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\$key]
"Desktop"=str(2):"%USERPROFILE%\\Desktop"
"Personal"=str(2):"%USERPROFILE%\\Documents"
"My Pictures"=str(2):"%USERPROFILE%\\Pictures"
"My Music"=str(2):"%USERPROFILE%\\Music"
"My Videos"=str(2):"%USERPROFILE%\\Videos"
"Downloads"=str(2):"%USERPROFILE%\\Downloads"
"Favorites"=str(2):"%USERPROFILE%\\Favorites"
"AppData"=str(2):"%USERPROFILE%\\AppData\\Roaming"
"Local AppData"=str(2):"%USERPROFILE%\\AppData\\Local"
"Local Settings"=str(2):"%USERPROFILE%\\AppData\\Local"
"Cache"=str(2):"%USERPROFILE%\\AppData\\Local\\Microsoft\\Windows\\INetCache"
"Cookies"=str(2):"%USERPROFILE%\\AppData\\Local\\Microsoft\\Windows\\INetCookies"
"History"=str(2):"%USERPROFILE%\\AppData\\Local\\Microsoft\\Windows\\History"
"Recent"=str(2):"%USERPROFILE%\\AppData\\Roaming\\Microsoft\\Windows\\Recent"
"SendTo"=str(2):"%USERPROFILE%\\AppData\\Roaming\\Microsoft\\Windows\\SendTo"
"Templates"=str(2):"%USERPROFILE%\\AppData\\Roaming\\Microsoft\\Windows\\Templates"
"Start Menu"=str(2):"%USERPROFILE%\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu"
"Programs"=str(2):"%USERPROFILE%\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs"
"Startup"=str(2):"%USERPROFILE%\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs\\StartUp"
"{4C5C32FF-BB9D-43B0-B5B4-2D72E54EAAA4}"=str(2):"%USERPROFILE%\\Saved Games"
REGEOF
  done
fi
grep -q '"Personal"' "$WORK/user.reg" \
  || die "failed to populate shell folders in prefix template"

# Create the directories those values point to.
for u in "$WORK/drive_c/users"/*; do
  [ -d "$u" ] || continue
  case "${u##*/}" in Public) continue;; esac
  mkdir -p "$u/Desktop" "$u/Documents" "$u/Pictures" "$u/Music" "$u/Videos" \
           "$u/Downloads" "$u/Favorites" "$u/Saved Games" \
           "$u/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/StartUp" \
           "$u/AppData/Local/Microsoft/Windows/INetCache"
done

cp -R "$WORK" "$DEST"

# Per-run state, not prefix content: .wineserver holds a lock and mappings for
# a server that is gone.
rm -rf "$DEST/.wineserver"

# dosdevices links must be relative or "/"; anything else names a path on this
# Mac and breaks on the phone.
for l in "$DEST/dosdevices"/*; do
  [ -L "$l" ] || continue
  t=$(readlink "$l")
  case "$t" in
    ../*|/) ;;
    *) die "dosdevices/$(basename "$l") -> $t is not portable" ;;
  esac
done

mkdir -p "$(dirname "$CACHE")"
rm -rf "$CACHE"
cp -R "$DEST" "$CACHE"

log "prefix template: $(du -sh "$DEST" | cut -f1)  ($(ls "$DEST" | wc -l | tr -d ' ') entries)"
log "  user dir: $(ls "$DEST/drive_c/users" 2>/dev/null | tr '\n' ' ')"
log "  cached for tree $TREE_HASH"

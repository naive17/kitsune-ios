#!/usr/bin/env bash
# Print the SHA-1 of the newest unrevoked Apple Development identity of the
# app's team (SIGN_TEAM, else KITSUNE_TEAM from local.env, else DEVELOPMENT_TEAM
# in kitsune-device.yml; an empty SIGN_TEAM accepts any team), or explain on stderr why there is none. Revocation is checked over
# OCSP because only Apple's answer agrees with what the phone accepts.
# Usage: ID=$(bash scripts/dev/signing-identity.sh) || exit 1
set -uo pipefail
cd "$(dirname "$0")/../.."
# shellcheck source=/dev/null
if [ -f local.env ]; then set -a; . ./local.env; set +a; fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
WWDR="$TMP/wwdr.pem"
curl -fsS -o "$TMP/wwdr.cer" https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer 2>/dev/null \
  && openssl x509 -inform der -in "$TMP/wwdr.cer" -out "$WWDR" 2>/dev/null || WWDR=""

security find-certificate -c "Apple Development" -a -p > "$TMP/all.pem" 2>/dev/null
awk 'BEGIN{n=0} /BEGIN CERTIFICATE/{n++; f=sprintf("'"$TMP"'/c%02d.pem",n)} {if(n>0) print > f}' "$TMP/all.pem"

# Pin the team: a certificate from another signed-in Apple ID would install a
# separate app, without access to this app's Documents.
WANT_TEAM="${SIGN_TEAM-${KITSUNE_TEAM:-$(awk '/DEVELOPMENT_TEAM:/{print $2; exit}' kitsune-device.yml)}}"

best_fp=""; best_nb=""; reasons=""; skipped_team=""
for f in "$TMP"/c*.pem; do
  [ -f "$f" ] || continue
  fp=$(openssl x509 -in "$f" -noout -fingerprint -sha1 2>/dev/null | sed 's/.*=//;s/://g')
  [ -n "$fp" ] || continue
  # Skip certificates whose private key is not in this keychain.
  security find-identity -v -p codesigning 2>/dev/null | grep -q "$fp" || continue
  # openssl separates subject fields with ',' or '/' depending on its version.
  ou=$(openssl x509 -in "$f" -noout -subject | tr ',/' '\n\n' | sed -n 's/.*OU=//p' | head -1 | tr -d ' ')
  if [ -n "$WANT_TEAM" ] && [ "$ou" != "$WANT_TEAM" ]; then
    skipped_team="$skipped_team\n  $fp  team $ou (not $WANT_TEAM)"
    continue
  fi
  nb=$(openssl x509 -in "$f" -noout -startdate | sed 's/notBefore=//')
  nbs=$(date -j -f "%b %e %T %Y %Z" "$nb" "+%s" 2>/dev/null || echo 0)

  status="unknown"
  if [ -n "$WWDR" ]; then
    uri=$(openssl x509 -in "$f" -noout -ocsp_uri 2>/dev/null)
    if [ -n "$uri" ]; then
      status=$(openssl ocsp -issuer "$WWDR" -cert "$f" -url "$uri" -header "Host=ocsp.apple.com" \
                 -noverify -resp_text 2>/dev/null | awk '/Cert Status:/{print $3; exit}')
      [ -n "$status" ] || status="unknown"
    fi
  fi
  if [ "$status" = "revoked" ]; then
    reasons="$reasons\n  $fp  REVOKED by Apple (notBefore $nb)"
    continue
  fi
  reasons="$reasons\n  $fp  $status (notBefore $nb)"
  if [ -z "$best_nb" ] || [ "$nbs" -gt "$best_nb" ]; then best_fp="$fp"; best_nb="$nbs"; fi
done

if [ -n "$best_fp" ]; then echo "$best_fp"; exit 0; fi

cat >&2 <<EOF
no usable signing identity: no Apple Development certificate with a private
key in this keychain is both from the expected team and not revoked by Apple.
$(printf '%b' "$reasons")
$( [ -n "$skipped_team" ] && printf 'Skipped, wrong team (set SIGN_TEAM to use another team):%b\n' "$skipped_team" )

Mint a new one -- it takes about twenty seconds and needs no project changes:
  Xcode -> Settings (Cmd-,) -> Accounts -> your Apple ID -> select the team
        -> Manage Certificates... -> "+" (bottom left) -> Apple Development

Then re-run. If Apple refuses because the team is at its certificate limit,
revoke an old one in the same dialog (right-click -> Revoke) and retry.
EOF
exit 1

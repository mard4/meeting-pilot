#!/usr/bin/env bash
# Notarizes and staples a Developer ID-signed .dmg or .pkg.
#
# One-time setup (stores an app-specific password in the login Keychain):
#   xcrun notarytool store-credentials meeting-pilot-notary \
#     --apple-id "email@appleid.com" --team-id "TEAMID"
# Then: NOTARY_KEYCHAIN_PROFILE=meeting-pilot-notary Scripts/notarize.sh <file>
set -euo pipefail

ARTIFACT="${1:?Uso: notarize.sh <file.dmg|file.pkg>}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:?Imposta NOTARY_KEYCHAIN_PROFILE (vedi xcrun notarytool store-credentials)}"

case "$ARTIFACT" in
  *.dmg) SPCTL_TYPE=open; SPCTL_EXTRA=(--context context:primary-signature) ;;
  *.pkg) SPCTL_TYPE=install; SPCTL_EXTRA=() ;;
  *) echo "Formato non supportato: $ARTIFACT (serve .dmg o .pkg)" >&2; exit 1 ;;
esac

SUBMISSION_JSON="$(xcrun notarytool submit "$ARTIFACT" \
  --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
  --wait \
  --output-format json)"
SUBMISSION_ID="$(/usr/bin/plutil -extract id raw -o - - <<< "$SUBMISSION_JSON")"
STATUS="$(/usr/bin/plutil -extract status raw -o - - <<< "$SUBMISSION_JSON")"

if [[ "$STATUS" != "Accepted" ]]; then
  echo "Notarizzazione $STATUS (id $SUBMISSION_ID). Log Apple:" >&2
  xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" >&2 || true
  exit 1
fi

xcrun stapler staple "$ARTIFACT"
xcrun stapler validate "$ARTIFACT"
spctl --assess --type "$SPCTL_TYPE" "${SPCTL_EXTRA[@]}" -vv "$ARTIFACT"
echo "$ARTIFACT"

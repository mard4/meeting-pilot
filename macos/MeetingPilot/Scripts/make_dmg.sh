#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
APP_SRC="$ROOT_DIR/macos/MeetingPilot"
BUILD_DIR="${MEETING_PILOT_BUILD_DIR:-$APP_SRC/build-current}"
APP_PATH="$BUILD_DIR/Meeting Pilot.app"
DMG_PATH="$BUILD_DIR/MeetingPilot.dmg"
STAGING="$BUILD_DIR/dmg-staging"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"

if [[ -n "$NOTARY_KEYCHAIN_PROFILE" && ( -z "$CODESIGN_IDENTITY" || "$CODESIGN_IDENTITY" == "-" ) ]]; then
  echo "La notarizzazione richiede CODESIGN_IDENTITY=\"Developer ID Application: ...\"." >&2
  exit 1
fi

app_signature_valid() {
  [[ -d "$APP_PATH" ]] && codesign --verify --deep --strict --verbose=2 "$APP_PATH" >/dev/null || return 1
  # An ad-hoc bundle left over from a local build must not end up in a Developer ID DMG.
  if [[ -n "$CODESIGN_IDENTITY" && "$CODESIGN_IDENTITY" != "-" ]]; then
    ! codesign -dv "$APP_PATH" 2>&1 | grep -q 'Signature=adhoc'
  fi
}

if ! app_signature_valid; then
  "$APP_SRC/Scripts/build_app.sh" >/dev/null
fi
app_signature_valid

rm -rf "$STAGING" "$DMG_PATH"
mkdir -p "$STAGING"
ditto "$APP_PATH" "$STAGING/Meeting Pilot.app"
codesign --verify --deep --strict --verbose=2 "$STAGING/Meeting Pilot.app" >/dev/null
cp "$APP_SRC/Guida post-installazione.txt" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
xattr -cr "$STAGING" 2>/dev/null || true

hdiutil create \
  -volname "Meeting Pilot" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

if [[ -n "$CODESIGN_IDENTITY" && "$CODESIGN_IDENTITY" != "-" ]]; then
  codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG_PATH"
fi

if [[ -n "$NOTARY_KEYCHAIN_PROFILE" ]]; then
  "$APP_SRC/Scripts/notarize.sh" "$DMG_PATH" >&2
fi

echo "$DMG_PATH"

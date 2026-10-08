#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
APP_SRC="$ROOT_DIR/macos/MeetingPilot"
BUILD_DIR="${MEETING_PILOT_BUILD_DIR:-$APP_SRC/build-current}"
APP_PATH="$BUILD_DIR/Meeting Pilot.app"
DMG_PATH="$BUILD_DIR/MeetingPilot.dmg"
STAGING="$BUILD_DIR/dmg-staging"
RW_DMG="$BUILD_DIR/MeetingPilot-rw.dmg"
VOLUME_NAME="Meeting Pilot"
# The same choice as build_app.sh: a Developer ID in the keychain is used without asking.
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-$(sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' <<< "$IDENTITIES" | sed -n 1p)}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"

if [[ -n "$NOTARY_KEYCHAIN_PROFILE" && "$CODESIGN_IDENTITY" != "Developer ID Application:"* ]]; then
  echo "La notarizzazione richiede CODESIGN_IDENTITY=\"Developer ID Application: ...\"." >&2
  exit 1
fi

app_signature_valid() {
  [[ -d "$APP_PATH" ]] && codesign --verify --deep --strict --verbose=2 "$APP_PATH" >/dev/null || return 1
  # A bundle left over from an ad hoc or self-signed build must not end up in a Developer
  # ID DMG: the app has to be signed by the identity the DMG is.
  if [[ -n "$CODESIGN_IDENTITY" && "$CODESIGN_IDENTITY" != "-" ]]; then
    # Read whole first: with pipefail, `grep -q` quitting early kills codesign with SIGPIPE.
    local details
    details="$(codesign -dv --verbose=2 "$APP_PATH" 2>&1)"
    grep -qxF "Authority=$CODESIGN_IDENTITY" <<< "$details"
  fi
}

if ! app_signature_valid; then
  "$APP_SRC/Scripts/build_app.sh" >/dev/null
fi
app_signature_valid

rm -rf "$STAGING" "$DMG_PATH" "$RW_DMG"
mkdir -p "$STAGING/.background"
ditto "$APP_PATH" "$STAGING/Meeting Pilot.app"
codesign --verify --deep --strict --verbose=2 "$STAGING/Meeting Pilot.app" >/dev/null
cp "$APP_SRC/assets/dmg_background.tiff" "$STAGING/.background/background.tiff"
ln -s /Applications "$STAGING/Applications"
xattr -cr "$STAGING" 2>/dev/null || true

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -fs HFS+ \
  -format UDRW \
  "$RW_DMG"

# Lay out the window the user sees on opening the DMG: the app on the left, an
# arrow on the background and the Applications link on the right.
MOUNT_DIR="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" | awk -F '\t' '/\/Volumes\// {print $NF; exit}')"
DISK_NAME="$(basename "$MOUNT_DIR")"
if ! osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$DISK_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 548}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 15
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "Meeting Pilot.app" of container window to {165, 190}
    set position of item "Applications" of container window to {495, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
then
  echo "Finder non ha applicato il layout del DMG (serve il permesso Automazione per Finder)." >&2
fi
sync
hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force -quiet

hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG_PATH"
rm -f "$RW_DMG"

# Apple's timestamp service only accepts its own certificates, and a self-signed DMG
# signature would add nothing: the app inside carries the signature that matters.
if [[ "$CODESIGN_IDENTITY" == "Developer ID Application:"* ]]; then
  codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG_PATH"
fi

if [[ -n "$NOTARY_KEYCHAIN_PROFILE" ]]; then
  "$APP_SRC/Scripts/notarize.sh" "$DMG_PATH" >&2
fi

echo "$DMG_PATH"

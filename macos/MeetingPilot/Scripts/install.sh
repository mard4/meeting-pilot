#!/usr/bin/env bash
# Installs the latest Meeting Pilot release into /Applications.
#   curl -fsSL https://raw.githubusercontent.com/mard4/meeting-pilot/main/macos/MeetingPilot/Scripts/install.sh | bash
set -euo pipefail

REPO="mard4/meeting-pilot"
DMG_URL="${MEETING_PILOT_DMG_URL:-https://github.com/$REPO/releases/latest/download/MeetingPilot.dmg}"
APP_NAME="Meeting Pilot.app"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Meeting Pilot runs on macOS only." >&2
  exit 1
fi

macos_major="$(sw_vers -productVersion | cut -d. -f1)"
if (( macos_major < 14 )); then
  echo "Meeting Pilot requires macOS 14 or later (found $(sw_vers -productVersion))." >&2
  exit 1
fi

# /Applications is writable for admin users; fall back to ~/Applications otherwise.
DEST="/Applications"
if [[ ! -w "$DEST" ]]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi

work="$(mktemp -d)"
mount_point="$work/mnt"
cleanup() {
  hdiutil detach "$mount_point" -quiet 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

echo "==> Downloading Meeting Pilot"
curl -fL --progress-bar "$DMG_URL" -o "$work/MeetingPilot.dmg"

echo "==> Mounting disk image"
mkdir -p "$mount_point"
hdiutil attach "$work/MeetingPilot.dmg" -nobrowse -readonly -quiet -mountpoint "$mount_point"

if [[ ! -d "$mount_point/$APP_NAME" ]]; then
  echo "$APP_NAME not found in the disk image." >&2
  exit 1
fi

# Checked on the mounted image, before the installed copy is touched: a broken or foreign
# signature stops the install instead of printing a warning after it.
signature="$(codesign -dv "$mount_point/$APP_NAME" 2>&1 || true)"
if ! codesign --verify --deep --strict "$mount_point/$APP_NAME" >/dev/null 2>&1 \
  || ! grep -qx 'Identifier=io.github.mard4.MeetingPilot' <<< "$signature" \
  || ! grep -qx 'TeamIdentifier=3F73JP5S4Q' <<< "$signature" \
  || ! spctl --assess --type execute "$mount_point/$APP_NAME" 2>/dev/null; then
  echo "The app signature in the disk image could not be verified; nothing was installed." >&2
  exit 1
fi

if pgrep -xq "Meeting Pilot"; then
  echo "==> Quitting the running copy"
  osascript -e 'quit app "Meeting Pilot"' 2>/dev/null || true
  sleep 2
fi

echo "==> Installing to $DEST"
rm -rf "$DEST/$APP_NAME"
ditto "$mount_point/$APP_NAME" "$DEST/$APP_NAME"

echo "==> Meeting Pilot installed in $DEST"
open "$DEST/$APP_NAME"

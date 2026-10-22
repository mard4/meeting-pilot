#!/usr/bin/env bash
# The browser extension as a zip for the GitHub release, next to the DMG:
#   build-current/MeetingPilot-Browser-Extension-X.Y.Z.zip
# Its version must be the app's, since the app copies the same folder to Application Support.
set -euo pipefail

APP_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$(cd "$APP_SRC/../.." && pwd)"
EXTENSION="$ROOT_DIR/browser/extension"
OUT_DIR="$APP_SRC/build-current"

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_SRC/Info.plist")"
EXTENSION_VERSION="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$EXTENSION/manifest.json")"
if [[ "$APP_VERSION" != "$EXTENSION_VERSION" ]]; then
  echo "La versione dell'estensione ($EXTENSION_VERSION) non è quella dell'app ($APP_VERSION): aggiorna browser/extension/manifest.json" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
ZIP="$OUT_DIR/MeetingPilot-Browser-Extension-$APP_VERSION.zip"
rm -f "$ZIP"
# The folder inside the zip is what "Load unpacked" is pointed at.
(cd "$ROOT_DIR/browser" && /usr/bin/ditto -c -k --keepParent --norsrc extension "$ZIP")
echo "$ZIP"

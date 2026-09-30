#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
APP_SRC="$ROOT_DIR/macos/MeetingPilot"
APP_BUILD_DIR="${MEETING_PILOT_BUILD_DIR:-$APP_SRC/build-current}"
PKG_BUILD_DIR="${MEETING_PILOT_PKG_DIR:-$APP_SRC/build-current}"
APP_PATH="$APP_BUILD_DIR/Meeting Pilot.app"
PKG_PATH="$PKG_BUILD_DIR/MeetingPilot.pkg"
COMPONENT_PKG_PATH="$PKG_BUILD_DIR/MeetingPilot-component.pkg"
UNSIGNED_PKG_PATH="$PKG_BUILD_DIR/MeetingPilot-unsigned.pkg"
PKG_ROOT="$PKG_BUILD_DIR/pkg-root"
COMPONENT_PLIST="$PKG_BUILD_DIR/components.plist"
INSTALLER_DISTRIBUTION_TEMPLATE="$APP_SRC/Installer/Distribution.xml"
INSTALLER_DISTRIBUTION="$PKG_BUILD_DIR/Distribution.xml"
INSTALLER_RESOURCES="$APP_SRC/Installer/Resources"
PRODUCTSIGN_IDENTITY="${PRODUCTSIGN_IDENTITY:-}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"

if [[ -n "$NOTARY_KEYCHAIN_PROFILE" && ( -z "$PRODUCTSIGN_IDENTITY" || "$PRODUCTSIGN_IDENTITY" == "-" ) ]]; then
  echo "La notarizzazione richiede PRODUCTSIGN_IDENTITY=\"Developer ID Installer: ...\"." >&2
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  MEETING_PILOT_BUILD_DIR="$APP_BUILD_DIR" "$APP_SRC/Scripts/build_app.sh" >/dev/null
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"

mkdir -p "$PKG_BUILD_DIR"
rm -rf "$PKG_PATH" "$COMPONENT_PKG_PATH" "$UNSIGNED_PKG_PATH" "$PKG_ROOT" "$COMPONENT_PLIST" "$INSTALLER_DISTRIBUTION"
mkdir -p "$PKG_ROOT/Applications"
ditto --noextattr --norsrc "$APP_PATH" "$PKG_ROOT/Applications/Meeting Pilot.app"

pkgbuild --analyze --root "$PKG_ROOT" "$COMPONENT_PLIST"
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$COMPONENT_PLIST"
/usr/libexec/PlistBuddy -c "Set :0:BundleIsVersionChecked false" "$COMPONENT_PLIST"

COPYFILE_DISABLE=1 pkgbuild \
  --root "$PKG_ROOT" \
  --install-location "/" \
  --component-plist "$COMPONENT_PLIST" \
  --identifier "$BUNDLE_ID.pkg" \
  --version "$VERSION" \
  "$COMPONENT_PKG_PATH"

sed "s/@VERSION@/$VERSION/g" "$INSTALLER_DISTRIBUTION_TEMPLATE" > "$INSTALLER_DISTRIBUTION"

productbuild \
  --distribution "$INSTALLER_DISTRIBUTION" \
  --resources "$INSTALLER_RESOURCES" \
  --package-path "$PKG_BUILD_DIR" \
  "$UNSIGNED_PKG_PATH"

if [[ -n "$PRODUCTSIGN_IDENTITY" && "$PRODUCTSIGN_IDENTITY" != "-" ]]; then
  productsign --sign "$PRODUCTSIGN_IDENTITY" "$UNSIGNED_PKG_PATH" "$PKG_PATH"
  rm -f "$UNSIGNED_PKG_PATH"
else
  mv "$UNSIGNED_PKG_PATH" "$PKG_PATH"
fi

if [[ -n "$NOTARY_KEYCHAIN_PROFILE" ]]; then
  "$APP_SRC/Scripts/notarize.sh" "$PKG_PATH" >&2
fi

echo "$PKG_PATH"

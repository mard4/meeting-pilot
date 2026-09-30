#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
APP_SRC="$ROOT_DIR/macos/MeetingPilot"
BUILD_DIR="${MEETING_PILOT_BUILD_DIR:-$APP_SRC/build-current}"
APP_DIR="$BUILD_DIR/Meeting Pilot.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
TOOLS="$RESOURCES/Tools"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
TARGET_ARCH="${MEETING_PILOT_TARGET_ARCH:-$(uname -m)}"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
SWIFT_TARGET="${TARGET_ARCH}-apple-macos${DEPLOYMENT_TARGET}"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_SRC/Info.plist")"
APP_ENTITLEMENTS="$APP_SRC/MeetingPilot.entitlements"
CLI_ENTITLEMENTS="$APP_SRC/MeetingPilotCLI.entitlements"

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES" "$TOOLS"

APP_ICON_SOURCE="$APP_SRC/assets/app_icon.png"
ICONSET_DIR="$APP_SRC/Resources/AppIcon.iconset"
ICON_PATH="$APP_SRC/Resources/AppIcon.icns"
if [[ -f "$APP_ICON_SOURCE" && ( ! -f "$ICON_PATH" || "${MEETING_PILOT_REGENERATE_ICON:-0}" == "1" ) ]]; then
  mkdir -p "$ICONSET_DIR"
  ICON_SPECS=(
    "16 icon_16x16.png"
    "32 icon_16x16@2x.png"
    "32 icon_32x32.png"
    "64 icon_32x32@2x.png"
    "128 icon_128x128.png"
    "256 icon_128x128@2x.png"
    "256 icon_256x256.png"
    "512 icon_256x256@2x.png"
    "512 icon_512x512.png"
    "1024 icon_512x512@2x.png"
  )
  for spec in "${ICON_SPECS[@]}"; do
    read -r size filename <<< "$spec"
    sips -z "$size" "$size" "$APP_ICON_SOURCE" --out "$ICONSET_DIR/$filename" >/dev/null
  done
  sips -z 1024 1024 "$APP_ICON_SOURCE" --out "$APP_SRC/Resources/AppIcon.png" >/dev/null
  iconutil -c icns "$ICONSET_DIR" -o "$ICON_PATH"
fi

cp "$APP_SRC/Info.plist" "$CONTENTS/Info.plist"
if compgen -G "$APP_SRC/Resources/*" > /dev/null; then
  cp -R "$APP_SRC/Resources/"* "$RESOURCES/"
fi
if compgen -G "$APP_SRC/assets/*" > /dev/null; then
  cp -R "$APP_SRC/assets/"* "$RESOURCES/"
fi

# FluidAudio is shipped ready to use: its CLI plus the Parakeet v3 ASR and
# speaker-diarization Core ML models live in the app resources.
FLUID_AUDIO_SOURCE="${FLUID_AUDIO_SOURCE:-$HOME/Library/Application Support/Meeting Pilot/FluidAudioRuntime/source}"
FLUID_AUDIO_MODELS="${FLUID_AUDIO_MODELS:-$HOME/Library/Application Support/FluidAudio/Models}"
FLUID_AUDIO_CLI="$FLUID_AUDIO_SOURCE/.build/release/fluidaudiocli"
if [[ ! -d "$FLUID_AUDIO_SOURCE" || ! -d "$FLUID_AUDIO_MODELS/parakeet-tdt-0.6b-v3" || ! -d "$FLUID_AUDIO_MODELS/speaker-diarization" ]]; then
  echo "FluidAudio e i modelli Parakeet v3 / diarizzazione sono richiesti per creare il bundle." >&2
  exit 1
fi
if [[ ! -x "$FLUID_AUDIO_CLI" ]]; then
  (cd "$FLUID_AUDIO_SOURCE" && xcrun swift build -c release --product fluidaudiocli)
fi
mkdir -p "$RESOURCES/FluidAudio/bin" "$RESOURCES/FluidAudio/Models"
cp "$FLUID_AUDIO_CLI" "$RESOURCES/FluidAudio/bin/fluidaudiocli"
cp -R "$FLUID_AUDIO_MODELS/parakeet-tdt-0.6b-v3" "$RESOURCES/FluidAudio/Models/"
cp -R "$FLUID_AUDIO_MODELS/speaker-diarization" "$RESOURCES/FluidAudio/Models/"

UV_BIN="${MEETING_PILOT_UV_BIN:-$(command -v uv || true)}"
if [[ -z "$UV_BIN" || ! -x "$UV_BIN" ]]; then
  echo "uv non trovato. Installalo sul Mac di build o imposta MEETING_PILOT_UV_BIN." >&2
  exit 1
fi
cp "$UV_BIN" "$TOOLS/uv"

# MeetingPilot links FluidAudio directly (for the live speaker-diarization sidebar), so
# it builds via SwiftPM instead of a raw `swiftc` invocation: SwiftPM's `--product
# FluidAudio` build only emits object files + a .swiftmodule for consumption inside an
# SPM build graph, not a standalone .a/.dylib that swiftc could link against directly.
FLUID_AUDIO_SOURCE="$FLUID_AUDIO_SOURCE" xcrun swift build \
  --package-path "$APP_SRC" \
  -c release \
  --product MeetingPilot \
  --arch "$TARGET_ARCH"
cp "$APP_SRC/.build/release/MeetingPilot" "$MACOS/MeetingPilot"

xcrun swiftc \
  -target "$SWIFT_TARGET" \
  -O \
  -parse-as-library \
  -framework Foundation \
  -framework Speech \
  "$APP_SRC/Sources/AppleTranscriber.swift" \
  -o "$MACOS/AppleTranscriber"

xcrun swiftc \
  -target "$SWIFT_TARGET" \
  -O \
  -parse-as-library \
  -framework Foundation \
  -framework NaturalLanguage \
  -Xlinker -weak_framework -Xlinker FoundationModels \
  -Xlinker -weak_framework -Xlinker Translation \
  "$APP_SRC/Sources/AppleIntelligenceSummarizer.swift" \
  -o "$MACOS/AppleIntelligenceSummarizer"

xcrun swiftc \
  -target "$SWIFT_TARGET" \
  -O \
  -framework AppKit \
  -framework Vision \
  "$ROOT_DIR/scripts/ocr_vision.swift" \
  -o "$MACOS/TeamsOCR"

xcrun swiftc \
  -target "$SWIFT_TARGET" \
  -O \
  -framework CoreGraphics \
  "$ROOT_DIR/scripts/teams_window_id.swift" \
  -o "$MACOS/TeamsWindowID"

# A fresh clone has no build environment yet: bootstrap it with uv (required above).
PYTHON_BIN="$ROOT_DIR/.venv311/bin/python"
if [[ ! -x "$PYTHON_BIN" ]]; then
  "$UV_BIN" venv --python 3.11 "$ROOT_DIR/.venv311"
fi
if ! "$PYTHON_BIN" -c 'import PyInstaller' >/dev/null 2>&1; then
  "$UV_BIN" pip install --python "$PYTHON_BIN" -e "$ROOT_DIR[build]"
fi
rm -rf "$BUILD_DIR/pyinstaller-work" "$BUILD_DIR/pyinstaller-dist"
PYTHONPATH="$ROOT_DIR/src" "$PYTHON_BIN" -m PyInstaller \
  --noconfirm \
  --clean \
  --onedir \
  --name MeetingPilotCLI \
  --paths "$ROOT_DIR/src" \
  --collect-all certifi \
  --collect-all notion_client \
  --hidden-import _struct \
  --exclude-module torch \
  --exclude-module mlx \
  --exclude-module mlx_audio \
  --exclude-module transformers \
  --distpath "$BUILD_DIR/pyinstaller-dist" \
  --workpath "$BUILD_DIR/pyinstaller-work" \
  --specpath "$BUILD_DIR" \
  "$APP_SRC/Scripts/packaging_entry.py"
cp -R "$BUILD_DIR/pyinstaller-dist/MeetingPilotCLI" "$RESOURCES/MeetingPilotCLI"

# Do not leave a superficially valid app bundle behind when a nested helper
# failed to compile or package. Deployment must only see complete bundles.
for required in \
  "$MACOS/MeetingPilot" \
  "$MACOS/AppleTranscriber" \
  "$MACOS/AppleIntelligenceSummarizer" \
  "$MACOS/TeamsOCR" \
  "$MACOS/TeamsWindowID" \
  "$RESOURCES/MeetingPilotCLI/MeetingPilotCLI"; do
  if [[ ! -f "$required" ]]; then
    echo "Build incompleta: manca $required" >&2
    exit 1
  fi
done

chmod +x "$MACOS/MeetingPilot" "$MACOS/AppleTranscriber" "$MACOS/AppleIntelligenceSummarizer" "$MACOS/TeamsOCR" "$MACOS/TeamsWindowID" "$RESOURCES/MeetingPilotCLI/MeetingPilotCLI" "$RESOURCES/FluidAudio/bin/fluidaudiocli" "$TOOLS/uv"

if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$TOOLS/uv"
  codesign --force --deep --sign - "$RESOURCES/MeetingPilotCLI/MeetingPilotCLI"
  codesign --force --sign - "$MACOS/TeamsOCR"
  codesign --force --sign - "$MACOS/TeamsWindowID"
  codesign --force --sign - "$MACOS/AppleTranscriber"
  codesign --force --sign - "$MACOS/AppleIntelligenceSummarizer"
  codesign --force --sign - "$RESOURCES/FluidAudio/bin/fluidaudiocli"
  codesign --force --sign - "$MACOS/MeetingPilot"
  # Keep the bundle identifier stable so macOS can retain its TCC permissions
  # across local ad-hoc rebuilds. --deep also seals the nested CLI helpers.
  codesign --force --deep --sign - --identifier "$BUNDLE_ID" \
    -r="designated => identifier \"$BUNDLE_ID\"" "$APP_DIR"
else
  # Notarization rejects any unsigned or non-hardened Mach-O, and --deep does not
  # reach the loose .so/.dylib files PyInstaller drops next to the CLI.
  developer_sign() {
    codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" "$@"
  }
  while IFS= read -r -d '' candidate; do
    if file -b "$candidate" | grep -q 'Mach-O'; then
      developer_sign "$candidate"
    fi
  done < <(find "$RESOURCES/MeetingPilotCLI" "$RESOURCES/FluidAudio" -type f -print0)
  developer_sign --entitlements "$CLI_ENTITLEMENTS" "$RESOURCES/MeetingPilotCLI/MeetingPilotCLI"
  developer_sign "$TOOLS/uv"
  developer_sign "$MACOS/TeamsOCR"
  developer_sign "$MACOS/TeamsWindowID"
  developer_sign "$MACOS/AppleTranscriber"
  developer_sign "$MACOS/AppleIntelligenceSummarizer"
  developer_sign "$RESOURCES/FluidAudio/bin/fluidaudiocli"
  # Signing the bundle last seals the helpers without re-signing them (no --deep),
  # so the CLI keeps its own entitlements.
  developer_sign --entitlements "$APP_ENTITLEMENTS" "$APP_DIR"
fi

codesign --verify --deep --strict --verbose=2 "$APP_DIR"
echo "$APP_DIR"

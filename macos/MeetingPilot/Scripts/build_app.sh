#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
APP_SRC="$ROOT_DIR/macos/MeetingPilot"
BUILD_DIR="${MEETING_PILOT_BUILD_DIR:-$APP_SRC/build-current}"
APP_DIR="$BUILD_DIR/Meeting Pilot.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
# Release builds sign with a certificate of their own ("Meeting Pilot Signing", made once in
# Keychain Access, see DISTRIBUZIONE.md) when it is in the keychain: unlike ad hoc signatures,
# which change with every build, it keeps the app's privacy permissions and login item valid
# across updates. Without it the build falls back to an ad hoc signature.
SELF_SIGNED_IDENTITY="${MEETING_PILOT_SIGNING_CERT:-Meeting Pilot Signing}"
# A Developer ID in the keychain always wins: a release that silently fell back to another
# signature would carry a designated requirement anyone can satisfy.
DEVELOPER_ID_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)"
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  if [[ -n "$DEVELOPER_ID_IDENTITY" ]]; then
    CODESIGN_IDENTITY="$DEVELOPER_ID_IDENTITY"
  elif security find-certificate -c "$SELF_SIGNED_IDENTITY" >/dev/null 2>&1; then
    CODESIGN_IDENTITY="$SELF_SIGNED_IDENTITY"
  else
    CODESIGN_IDENTITY="-"
  fi
fi
TARGET_ARCH="${MEETING_PILOT_TARGET_ARCH:-$(uname -m)}"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
SWIFT_TARGET="${TARGET_ARCH}-apple-macos${DEPLOYMENT_TARGET}"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_SRC/Info.plist")"
APP_ENTITLEMENTS="$APP_SRC/MeetingPilot.entitlements"
CLI_ENTITLEMENTS="$APP_SRC/MeetingPilotCLI.entitlements"

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

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

# FluidAudio's CLI and its speaker-diarization Core ML models live in the app
# resources. The Parakeet v3 speech model (~460 MB) is not bundled: from macOS 26
# Apple's recognizer transcribes, and the app downloads Parakeet on request.
FLUID_AUDIO_SOURCE="${FLUID_AUDIO_SOURCE:-$HOME/Library/Application Support/Meeting Pilot/FluidAudioRuntime/source}"
FLUID_AUDIO_MODELS="${FLUID_AUDIO_MODELS:-$HOME/Library/Application Support/FluidAudio/Models}"
FLUID_AUDIO_CLI="$FLUID_AUDIO_SOURCE/.build/release/fluidaudiocli"
# Offline diarization (VBx), which the pipeline uses for recordings, needs the
# Segmentation/Embedding models next to the streaming ones; FluidAudio downloads them
# the first time `fluidaudiocli process --mode offline` runs.
if [[ ! -d "$FLUID_AUDIO_SOURCE" || ! -d "$FLUID_AUDIO_MODELS/speaker-diarization/Segmentation.mlmodelc" || ! -d "$FLUID_AUDIO_MODELS/speaker-diarization/Embedding.mlmodelc" ]]; then
  echo "FluidAudio e i modelli di diarizzazione (anche offline) sono richiesti per creare il bundle." >&2
  echo "Scaricali una volta con: fluidaudiocli process <audio> --mode offline" >&2
  exit 1
fi
# The checkout lives in a folder any process of this account can write, and both the app
# and the CLI are built from it: build only the pinned revision, with no local changes.
FLUID_AUDIO_REF="${FLUID_AUDIO_REF:-b68f484789d81fda21efbf81e2ca9fcfd9dc22aa}"
if [[ "$(git -C "$FLUID_AUDIO_SOURCE" rev-parse HEAD 2>/dev/null)" != "$FLUID_AUDIO_REF" ]]; then
  git -C "$FLUID_AUDIO_SOURCE" fetch --quiet origin "$FLUID_AUDIO_REF"
  git -C "$FLUID_AUDIO_SOURCE" checkout --quiet "$FLUID_AUDIO_REF"
  rm -f "$FLUID_AUDIO_CLI"
fi
if [[ -n "$(git -C "$FLUID_AUDIO_SOURCE" status --porcelain --untracked-files=no)" ]]; then
  echo "FluidAudio ha modifiche locali in $FLUID_AUDIO_SOURCE: annullale prima di creare il bundle." >&2
  exit 1
fi
if [[ ! -x "$FLUID_AUDIO_CLI" ]]; then
  (cd "$FLUID_AUDIO_SOURCE" && xcrun swift build -c release --product fluidaudiocli)
fi
mkdir -p "$RESOURCES/FluidAudio/bin" "$RESOURCES/FluidAudio/Models"
cp "$FLUID_AUDIO_CLI" "$RESOURCES/FluidAudio/bin/fluidaudiocli"
cp -R "$FLUID_AUDIO_MODELS/speaker-diarization" "$RESOURCES/FluidAudio/Models/"

# The Meeting Pilot model's engine: llama.cpp's server from a pinned commit, built as one
# self-contained binary (static libraries, Metal shaders embedded, only system frameworks
# linked). The models themselves (572 MB / 2.5 GB) are downloaded by the app on request.
LLAMA_CPP_REF="${LLAMA_CPP_REF:-d81235049384534c167caea52b85a694f6103d14}"  # llama.cpp 0.6.0
LLAMA_CPP_SOURCE="${LLAMA_CPP_SOURCE:-$HOME/Library/Application Support/Meeting Pilot/LlamaCppRuntime/source}"
LLAMA_CPP_BUILD="$LLAMA_CPP_SOURCE/build-static-$TARGET_ARCH"
LLAMA_SERVER_BIN="$LLAMA_CPP_BUILD/bin/llama-server"
if [[ ! -d "$LLAMA_CPP_SOURCE/.git" ]]; then
  git clone --quiet --filter=blob:none https://github.com/ggml-org/llama.cpp "$LLAMA_CPP_SOURCE"
fi
if [[ "$(git -C "$LLAMA_CPP_SOURCE" rev-parse HEAD)" != "$LLAMA_CPP_REF"* || ! -x "$LLAMA_SERVER_BIN" ]]; then
  if ! command -v cmake >/dev/null; then
    echo "cmake non trovato: serve per compilare llama.cpp (brew install cmake)." >&2
    exit 1
  fi
  git -C "$LLAMA_CPP_SOURCE" fetch --quiet origin "$LLAMA_CPP_REF"
  git -C "$LLAMA_CPP_SOURCE" checkout --quiet "$LLAMA_CPP_REF"
  cmake -S "$LLAMA_CPP_SOURCE" -B "$LLAMA_CPP_BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$TARGET_ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_CCACHE=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_SERVER=ON \
    -DLLAMA_CURL=OFF \
    -DLLAMA_OPENSSL=OFF >/dev/null
  cmake --build "$LLAMA_CPP_BUILD" --config Release --target llama-server -j "$(sysctl -n hw.ncpu)" >/dev/null
fi
mkdir -p "$RESOURCES/LlamaCpp/bin"
cp "$LLAMA_SERVER_BIN" "$RESOURCES/LlamaCpp/bin/llama-server"

UV_BIN="${MEETING_PILOT_UV_BIN:-$(command -v uv || true)}"
if [[ -z "$UV_BIN" || ! -x "$UV_BIN" ]]; then
  echo "uv non trovato. Installalo sul Mac di build o imposta MEETING_PILOT_UV_BIN." >&2
  exit 1
fi

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
  "$APP_SRC/Sources/Transcription/AppleTranscriber.swift" \
  -o "$MACOS/AppleTranscriber"

xcrun swiftc \
  -target "$SWIFT_TARGET" \
  -O \
  -parse-as-library \
  -framework Foundation \
  -framework NaturalLanguage \
  -Xlinker -weak_framework -Xlinker FoundationModels \
  -Xlinker -weak_framework -Xlinker Translation \
  "$APP_SRC/Sources/Summarization/AppleIntelligenceSummarizer.swift" \
  -o "$MACOS/AppleIntelligenceSummarizer"

xcrun swiftc \
  -target "$SWIFT_TARGET" \
  -O \
  -framework AppKit \
  -framework Vision \
  "$APP_SRC/Scripts/ocr_vision.swift" \
  -o "$MACOS/TeamsOCR"

xcrun swiftc \
  -target "$SWIFT_TARGET" \
  -O \
  -framework CoreGraphics \
  "$APP_SRC/Scripts/teams_window_id.swift" \
  -o "$MACOS/TeamsWindowID"

# A fresh clone has no build environment yet: bootstrap it with uv (required above).
PYTHON_BIN="$ROOT_DIR/.venv311/bin/python"
if [[ ! -x "$PYTHON_BIN" ]]; then
  "$UV_BIN" venv --python 3.11 "$ROOT_DIR/.venv311"
fi
if ! "$PYTHON_BIN" -c 'import PyInstaller' >/dev/null 2>&1; then
  # Exactly the versions in uv.lock, each checked against its hash, as they end up in the app.
  LOCKED_REQUIREMENTS="$(mktemp)"
  (cd "$ROOT_DIR" && "$UV_BIN" export --locked --extra build --no-emit-project --format requirements-txt -q -o "$LOCKED_REQUIREMENTS")
  "$UV_BIN" pip install --python "$PYTHON_BIN" --require-hashes -r "$LOCKED_REQUIREMENTS"
  "$UV_BIN" pip install --python "$PYTHON_BIN" --no-deps -e "$ROOT_DIR[build]"
  rm -f "$LOCKED_REQUIREMENTS"
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

chmod +x "$MACOS/MeetingPilot" "$MACOS/AppleTranscriber" "$MACOS/AppleIntelligenceSummarizer" "$MACOS/TeamsOCR" "$MACOS/TeamsWindowID" "$RESOURCES/MeetingPilotCLI/MeetingPilotCLI" "$RESOURCES/FluidAudio/bin/fluidaudiocli" "$RESOURCES/LlamaCpp/bin/llama-server"

if [[ "$CODESIGN_IDENTITY" != "Developer ID Application:"* ]]; then
  # Ad hoc ("-") or a self-signed certificate. Everything but the PyInstaller CLI gets the
  # hardened runtime, which stops DYLD_INSERT_LIBRARIES and unsigned libraries from running
  # inside an app that holds microphone, audio, Accessibility and Automation permissions.
  # The CLI cannot: without a Team ID library validation would refuse its libraries.
  local_sign() {
    codesign --force --sign "$CODESIGN_IDENTITY" "$@"
  }
  hardened_sign() {
    local_sign --options runtime "$@"
  }
  local_sign --deep "$RESOURCES/MeetingPilotCLI/MeetingPilotCLI"
  hardened_sign "$MACOS/TeamsOCR"
  hardened_sign "$MACOS/TeamsWindowID"
  hardened_sign "$MACOS/AppleTranscriber"
  hardened_sign "$MACOS/AppleIntelligenceSummarizer"
  hardened_sign "$RESOURCES/FluidAudio/bin/fluidaudiocli"
  hardened_sign "$RESOURCES/LlamaCpp/bin/llama-server"
  # Signing the bundle last seals the helpers without re-signing them (no --deep), so
  # they keep their own flags; the entitlements are what the hardened runtime requires
  # for the microphone and Apple Events.
  if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
    # Keep the bundle identifier stable so macOS can retain its TCC permissions
    # across local ad-hoc rebuilds.
    hardened_sign --entitlements "$APP_ENTITLEMENTS" --identifier "$BUNDLE_ID" \
      -r="designated => identifier \"$BUNDLE_ID\"" "$APP_DIR"
  else
    # The default designated requirement names the certificate, which stays the same
    # from one release to the next.
    hardened_sign --entitlements "$APP_ENTITLEMENTS" --identifier "$BUNDLE_ID" "$APP_DIR"
  fi
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
  developer_sign "$MACOS/TeamsOCR"
  developer_sign "$MACOS/TeamsWindowID"
  developer_sign "$MACOS/AppleTranscriber"
  developer_sign "$MACOS/AppleIntelligenceSummarizer"
  developer_sign "$RESOURCES/FluidAudio/bin/fluidaudiocli"
  developer_sign "$RESOURCES/LlamaCpp/bin/llama-server"
  # Signing the bundle last seals the helpers without re-signing them (no --deep),
  # so the CLI keeps its own entitlements.
  developer_sign --entitlements "$APP_ENTITLEMENTS" "$APP_DIR"
fi

codesign --verify --deep --strict --verbose=2 "$APP_DIR"
echo "$APP_DIR"

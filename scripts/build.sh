#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
TARGETS="${ARCHS:-arm64 x86_64}"
MACOS_MIN_VERSION="${MACOS_MIN_VERSION:-13.0}"
PI_APP_NAME="Pi Space.app"
WAKE_APP_NAME="Wake Pi Listener.app"
WAKE_IDENTIFIER="com.pispace.wake-listener"
PI_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
PI_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Resources/Info.plist")"
SWIFTC="$(xcrun --find swiftc)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

usage() {
  cat <<'EOF'
Usage: ./scripts/build.sh [--pi-only | --wake-only] [--clean]

Builds universal (Apple silicon + Intel) macOS app bundles into dist/.
Environment overrides: ARCHS, MACOS_MIN_VERSION, BUILD_DIR, DIST_DIR.
EOF
}

BUILD_PI=1
BUILD_WAKE=1
CLEAN=0
while (($#)); do
  case "$1" in
    --pi-only) BUILD_WAKE=0 ;;
    --wake-only) BUILD_PI=0 ;;
    --clean) CLEAN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[[ "$(uname -s)" == "Darwin" ]] || { echo "Pi Space can only be built on macOS." >&2; exit 1; }
command -v xcrun >/dev/null || { echo "Install Xcode Command Line Tools: xcode-select --install" >&2; exit 1; }
command -v lipo >/dev/null || { echo "The lipo tool is required." >&2; exit 1; }
command -v codesign >/dev/null || { echo "The codesign tool is required." >&2; exit 1; }

TARGETS_ARRAY=()
for arch in $TARGETS; do
  case "$arch" in
    arm64|x86_64) TARGETS_ARRAY+=("$arch") ;;
    *) echo "Unsupported architecture in ARCHS: $arch" >&2; exit 2 ;;
  esac
done
((${#TARGETS_ARRAY[@]})) || { echo "ARCHS must contain arm64 and/or x86_64." >&2; exit 2; }

if ((CLEAN)); then
  rm -rf "$BUILD_DIR" "$DIST_DIR"
fi
mkdir -p "$BUILD_DIR" "$DIST_DIR"

compile_universal() {
  local source="$1"
  local output="$2"
  shift 2
  local frameworks=("$@")
  local binaries=()

  for arch in "${TARGETS_ARRAY[@]}"; do
    local binary="$BUILD_DIR/$(basename "$output")-$arch"
    local command=(
      "$SWIFTC"
      -O
      -sdk "$SDK"
      -target "${arch}-apple-macosx${MACOS_MIN_VERSION}"
      -o "$binary"
      "$source"
    )
    for framework in "${frameworks[@]}"; do
      command+=(-framework "$framework")
    done
    echo "Compiling $(basename "$source") for ${arch}..."
    "${command[@]}"
    binaries+=("$binary")
  done

  if ((${#binaries[@]} == 1)); then
    cp "${binaries[0]}" "$output"
  else
    lipo -create "${binaries[@]}" -output "$output"
  fi
  chmod 755 "$output"
}

sign_bundle() {
  local bundle="$1"
  if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    codesign --force --deep --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$bundle"
  else
    codesign --force --deep --sign - "$bundle"
  fi
}

build_pi() {
  local app="$DIST_DIR/$PI_APP_NAME"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  compile_universal "$ROOT/Sources/PiSpace.swift" "$app/Contents/MacOS/PiSpace" AppKit WebKit
  cp "$ROOT/Resources/Info.plist" "$app/Contents/Info.plist"
  cp "$ROOT/Resources/PiSpace.html" "$ROOT/Resources/PiSpace.icns" "$app/Contents/Resources/"
  sign_bundle "$app"
  echo "Built $app"
}

write_wake_plist() {
  local destination="$1"
  cat > "$destination" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>Wake Pi Listener</string>
  <key>CFBundleExecutable</key>
  <string>WakePi</string>
  <key>CFBundleIdentifier</key>
  <string>$WAKE_IDENTIFIER</string>
  <key>CFBundleName</key>
  <string>Wake Pi Listener</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$PI_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$PI_BUILD</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MACOS_MIN_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Listens for the phrases "wake up Pi" and "time for bed Pi" so it can open or close Pi Space.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Recognizes the phrases "wake up Pi" and "time for bed Pi" to control Pi Space.</string>
</dict>
</plist>
EOF
}

build_wake() {
  local app="$DIST_DIR/$WAKE_APP_NAME"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS"
  compile_universal "$ROOT/Sources/WakePi.swift" "$app/Contents/MacOS/WakePi" AppKit AVFoundation Speech
  write_wake_plist "$app/Contents/Info.plist"
  sign_bundle "$app"
  echo "Built $app"
}

((BUILD_PI)) && build_pi
((BUILD_WAKE)) && build_wake

echo "Build complete."

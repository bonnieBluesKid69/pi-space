#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_FIRST=1

usage() {
  cat <<'EOF'
Usage: ./scripts/package.sh [--no-build]

Creates a versioned macOS ZIP, DMG, and SHA-256 checksums in release/.
Set CODESIGN_IDENTITY before running to use a Developer ID signature.
EOF
}

while (($#)); do
  case "$1" in
    --no-build) BUILD_FIRST=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if ((BUILD_FIRST)); then
  "$ROOT/scripts/build.sh" --clean
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
RELEASE_DIR="$ROOT/release"
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

for item in "Pi Space.app|Pi-Space-$VERSION-macOS.zip" "Wake Pi Listener.app|Wake-Pi-Listener-$VERSION-macOS.zip"; do
  app="${item%%|*}"
  archive="${item#*|}"
  [[ -d "$ROOT/dist/$app" ]] || { echo "Missing dist/$app" >&2; exit 1; }
  COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$ROOT/dist/$app" "$RELEASE_DIR/$archive"
done

DMG="$RELEASE_DIR/Pi-Space-macOS.dmg"
DMG_STAGE="$ROOT/build/dmg-stage"
rm -rf "$DMG_STAGE" "$DMG"
mkdir -p "$DMG_STAGE"
cp -R "$ROOT/dist/Pi Space.app" "$DMG_STAGE/Pi Space.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "Pi Space $VERSION" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG" >/dev/null

(
  cd "$RELEASE_DIR"
  shasum -a 256 ./*.zip Pi-Space-macOS.dmg > SHA256SUMS.txt
  shasum -a 256 Pi-Space-macOS.dmg > Pi-Space-macOS.sha256
)

echo "Release archives created in $RELEASE_DIR"

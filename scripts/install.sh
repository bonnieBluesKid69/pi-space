#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
INSTALL_WAKE=0
BUILD_FIRST=1
OPEN_AFTER=1

usage() {
  cat <<'EOF'
Usage: ./scripts/install.sh [options]

Options:
  --with-wake-listener  Also install and start the optional voice listener
  --no-build            Install existing bundles from dist/
  --no-open             Do not open Pi Space after installation
  -h, --help            Show this help

Set INSTALL_DIR to install somewhere other than ~/Applications.
EOF
}

while (($#)); do
  case "$1" in
    --with-wake-listener) INSTALL_WAKE=1 ;;
    --no-build) BUILD_FIRST=0 ;;
    --no-open) OPEN_AFTER=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[[ "$(uname -s)" == "Darwin" ]] || { echo "Pi Space only runs on macOS." >&2; exit 1; }

if ((BUILD_FIRST)); then
  if ((INSTALL_WAKE)); then
    "$ROOT/scripts/build.sh"
  else
    "$ROOT/scripts/build.sh" --pi-only
  fi
fi

SOURCE_APP="$ROOT/dist/Pi Space.app"
[[ -d "$SOURCE_APP" ]] || { echo "Missing $SOURCE_APP. Run ./scripts/build.sh first." >&2; exit 1; }
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/Pi Space.app"
cp -R "$SOURCE_APP" "$INSTALL_DIR/Pi Space.app"

if ((INSTALL_WAKE)); then
  SOURCE_WAKE="$ROOT/dist/Wake Pi Listener.app"
  [[ -d "$SOURCE_WAKE" ]] || { echo "Missing $SOURCE_WAKE. Run ./scripts/build.sh first." >&2; exit 1; }
  pkill -x WakePi 2>/dev/null || true
  rm -rf "$INSTALL_DIR/Wake Pi Listener.app"
  cp -R "$SOURCE_WAKE" "$INSTALL_DIR/Wake Pi Listener.app"
  open "$INSTALL_DIR/Wake Pi Listener.app"
fi

if ((OPEN_AFTER)); then
  open "$INSTALL_DIR/Pi Space.app"
fi

echo "Installed Pi Space to $INSTALL_DIR/Pi Space.app"
if ((INSTALL_WAKE)); then
  echo "Installed Wake Pi Listener to $INSTALL_DIR/Wake Pi Listener.app"
fi

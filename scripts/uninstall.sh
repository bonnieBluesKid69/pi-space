#!/bin/bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"

pkill -x WakePi 2>/dev/null || true
pkill -x PiSpace 2>/dev/null || true
rm -rf "$INSTALL_DIR/Pi Space.app" "$INSTALL_DIR/Wake Pi Listener.app"

echo "Removed Pi Space and Wake Pi Listener from $INSTALL_DIR"
echo "Your Pi configuration and sessions in ~/.pi/agent were left untouched."

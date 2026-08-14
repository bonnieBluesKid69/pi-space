#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Checking source files..."
"$ROOT/scripts/check.sh"

echo "Building app bundles..."
"$ROOT/scripts/build.sh" --clean

PI_APP="$ROOT/dist/Pi Space.app"
WAKE_APP="$ROOT/dist/Wake Pi Listener.app"

for app in "$PI_APP" "$WAKE_APP"; do
  [[ -d "$app" ]] || { echo "Missing bundle: $app" >&2; exit 1; }
  codesign --verify --deep --strict "$app"
  plutil -lint "$app/Contents/Info.plist" >/dev/null
done

[[ -f "$PI_APP/Contents/Resources/PiSpace.html" ]]
[[ -f "$PI_APP/Contents/Resources/PiSpace.icns" ]]
[[ "$(lipo -archs "$PI_APP/Contents/MacOS/PiSpace")" == *arm64* ]]
[[ "$(lipo -archs "$PI_APP/Contents/MacOS/PiSpace")" == *x86_64* ]]
[[ "$(lipo -archs "$WAKE_APP/Contents/MacOS/WakePi")" == *arm64* ]]
[[ "$(lipo -archs "$WAKE_APP/Contents/MacOS/WakePi")" == *x86_64* ]]

RPC_STDERR="$(mktemp -t pi-space-rpc-stderr.XXXXXX)"
trap 'rm -f "$RPC_STDERR"' EXIT
if command -v pi >/dev/null 2>&1; then
  printf '{"type":"get_state"}\n' | pi --mode rpc --no-session 2>"$RPC_STDERR" | \
    python3 -c 'import json,sys
for line in sys.stdin:
    data=json.loads(line)
    if data.get("type") == "response" and data.get("command") == "get_state":
        if not data.get("success"):
            raise SystemExit("Pi RPC get_state failed")
        raise SystemExit(0)
raise SystemExit("Pi RPC returned no get_state response")'
else
  echo "Skipping Pi RPC smoke test because pi is not installed."
fi

echo "All checks passed."

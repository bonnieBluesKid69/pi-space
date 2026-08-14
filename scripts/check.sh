#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[[ "$(uname -s)" == "Darwin" ]] || { echo "Checks require macOS." >&2; exit 1; }
command -v xcrun >/dev/null || { echo "Install Xcode Command Line Tools: xcode-select --install" >&2; exit 1; }

plutil -lint "$ROOT/Resources/Info.plist"
xcrun swiftc -typecheck -target arm64-apple-macosx13.0 \
  -framework AppKit -framework WebKit "$ROOT/Sources/PiSpace.swift"
xcrun swiftc -typecheck -target arm64-apple-macosx13.0 \
  -framework AppKit -framework AVFoundation -framework Speech "$ROOT/Sources/WakePi.swift"

python3 - "$ROOT/Resources/PiSpace.html" <<'PY'
from html.parser import HTMLParser
from pathlib import Path
import sys

class Parser(HTMLParser):
    pass

path = Path(sys.argv[1])
parser = Parser()
parser.feed(path.read_text(encoding="utf-8"))
parser.close()
PY

PATTERN='(BEGIN [A-Z ]*PRIVATE KEY|github_pat_|ghp_[A-Za-z0-9]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,}|AKIA[0-9A-Z]{16}|xox[baprs]-)'
SCAN_PATHS=(
  "$ROOT/Sources" "$ROOT/Resources" "$ROOT/scripts" "$ROOT/docs"
  "$ROOT/README.md" "$ROOT/SECURITY.md" "$ROOT/CONTRIBUTING.md"
)
MATCHES="$(grep -ERnI --exclude='PiSpace.icns' --exclude='check.sh' -- "$PATTERN" "${SCAN_PATHS[@]}" || true)"
if [[ -n "$MATCHES" ]]; then
  printf '%s\n' "$MATCHES"
  echo "Possible secret detected. Review the matches above." >&2
  exit 1
fi

echo "Source checks passed."

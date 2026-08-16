#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${HOME}/Library/Application Support/Pi Space/kokoro"
VENV_DIR="$DATA_DIR/venv"
STAGING_VENV="$DATA_DIR/venv-installing"
PYTHON=""
FAILED_STEP="Preparing the installer"
LOG_DIR="${HOME}/Library/Logs/Pi Space"
LOG_FILE="$LOG_DIR/kokoro-install.log"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1
printf '\n[%s] Starting Kokoro installation\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
trap 'code=$?; printf "Kokoro installation failed while %s (exit %s). Review %s\n" "$FAILED_STEP" "$code" "$LOG_FILE" >&2; exit "$code"' ERR

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "Kokoro local voice requires Apple Silicon." >&2
  exit 1
fi
CANDIDATES=(
  /opt/homebrew/opt/python@3.12/bin/python3.12
  /opt/homebrew/opt/python@3.11/bin/python3.11
  /opt/homebrew/opt/python@3.10/bin/python3.10
  /opt/homebrew/bin/python3.12
  /opt/homebrew/bin/python3.11
  /opt/homebrew/bin/python3.10
  /usr/local/opt/python@3.12/bin/python3.12
  /usr/local/opt/python@3.11/bin/python3.11
  /usr/local/opt/python@3.10/bin/python3.10
  /usr/local/bin/python3.12
  /usr/local/bin/python3.11
  /usr/local/bin/python3.10
  /Library/Frameworks/Python.framework/Versions/3.12/bin/python3
  /Library/Frameworks/Python.framework/Versions/3.11/bin/python3
  /Library/Frameworks/Python.framework/Versions/3.10/bin/python3
  python3.12 python3.11 python3.10 python3
)
for candidate in "${CANDIDATES[@]}"; do
  path="$candidate"
  [[ "$candidate" == /* ]] || path="$(command -v "$candidate" 2>/dev/null || true)"
  if [[ -n "$path" && -x "$path" ]] && "$path" -c 'import sys; raise SystemExit(0 if (3,10) <= sys.version_info[:2] <= (3,12) else 1)' 2>/dev/null; then
    PYTHON="$path"
    break
  fi
done
if [[ -z "$PYTHON" ]]; then
  trap - ERR
  echo "Kokoro needs Python 3.10, 3.11, or 3.12. Install Python 3.12 from python.org or run: brew install python@3.12" >&2
  exit 1
fi
printf 'Using %s (%s)\n' "$PYTHON" "$("$PYTHON" -c 'import sys; print(sys.version.split()[0])')"
mkdir -p "$DATA_DIR"
if [[ ! -x "$VENV_DIR/bin/python3" ]] || ! "$VENV_DIR/bin/python3" -c 'import mlx_audio, soundfile, huggingface_hub' >/dev/null 2>&1; then
  rm -rf "$STAGING_VENV"
  FAILED_STEP="creating the Python environment"
  "$PYTHON" -m venv "$STAGING_VENV"
  FAILED_STEP="updating pip"
  "$STAGING_VENV/bin/python3" -m pip install --upgrade pip
  FAILED_STEP="installing voice dependencies"
  "$STAGING_VENV/bin/python3" -m pip install mlx-audio soundfile scipy loguru \
    'misaki==0.8.4' num2words spacy phonemizer-fork espeakng_loader pysbd ftfy pylatexenc
  FAILED_STEP="validating voice dependencies"
  "$STAGING_VENV/bin/python3" -c 'import mlx_audio, soundfile, huggingface_hub'
  rm -rf "$VENV_DIR.previous"
  [[ ! -d "$VENV_DIR" ]] || mv "$VENV_DIR" "$VENV_DIR.previous"
  if ! mv "$STAGING_VENV" "$VENV_DIR"; then
    [[ ! -d "$VENV_DIR.previous" ]] || mv "$VENV_DIR.previous" "$VENV_DIR"
    echo "Could not activate the new Kokoro environment; the previous installation was restored." >&2
    exit 1
  fi
  rm -rf "$VENV_DIR.previous"
fi
if ! "$VENV_DIR/bin/python3" -c "from huggingface_hub import try_to_load_from_cache; assert try_to_load_from_cache('mlx-community/Kokoro-82M-bf16', 'config.json') is not None" >/dev/null 2>&1; then
  FAILED_STEP="downloading the Kokoro model"
  "$VENV_DIR/bin/python3" -c "from huggingface_hub import snapshot_download; snapshot_download('mlx-community/Kokoro-82M-bf16')"
fi
FAILED_STEP="copying the local voice server"
SERVER_SOURCE="$SCRIPT_DIR/kokoro-tts-server.py"
if [[ ! -f "$SERVER_SOURCE" ]]; then
  SERVER_SOURCE="$SCRIPT_DIR/../Resources/kokoro-tts-server.py"
fi
[[ -f "$SERVER_SOURCE" ]] || { echo "Kokoro server resource is missing." >&2; exit 1; }
cp "$SERVER_SOURCE" "$DATA_DIR/tts-server.py"
printf '%s\n' "$VENV_DIR/bin/python3" > "$DATA_DIR/python-path"
printf '%s\n' 'installed' > "$DATA_DIR/status"
trap - ERR
printf '[%s] Kokoro is installed at %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$DATA_DIR"

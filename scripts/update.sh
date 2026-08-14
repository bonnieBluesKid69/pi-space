#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE="${PI_SPACE_UPDATE_REMOTE:-origin}"
BRANCH="${PI_SPACE_UPDATE_BRANCH:-main}"
CHECK_ONLY=0
WAKE_MODE="auto"
OPEN_AFTER=1

usage() {
  cat <<'EOF'
Usage: ./scripts/update.sh [options]

Fetch the latest Pi Space source from GitHub, fast-forward the current
checkout, rebuild the apps, and reinstall them.

Options:
  --check                 Check whether an update is available
  --with-wake-listener    Install or update Wake Pi Listener
  --without-wake-listener Do not install or update Wake Pi Listener
  --no-open               Do not open Pi Space after updating
  -h, --help              Show this help

By default, Wake Pi Listener is updated only when it is already installed.
Environment overrides: PI_SPACE_UPDATE_REMOTE, PI_SPACE_UPDATE_BRANCH, INSTALL_DIR.
EOF
}

while (($#)); do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    --with-wake-listener) WAKE_MODE="yes" ;;
    --without-wake-listener) WAKE_MODE="no" ;;
    --no-open) OPEN_AFTER=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[[ "$(uname -s)" == "Darwin" ]] || { echo "Pi Space only runs on macOS." >&2; exit 1; }
command -v git >/dev/null || { echo "Git is required to update Pi Space." >&2; exit 1; }
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "Pi Space must be updated from a Git checkout." >&2
  echo "Clone https://github.com/bonnieBluesKid69/pi-space.git, then run scripts/update.sh." >&2
  exit 1
}
git -C "$ROOT" remote get-url "$REMOTE" >/dev/null 2>&1 || {
  echo "Git remote '$REMOTE' is not configured." >&2
  exit 1
}

if [[ -n "$(git -C "$ROOT" status --porcelain)" ]] && ((CHECK_ONLY == 0)); then
  echo "Update stopped because the Pi Space checkout has local changes:" >&2
  git -C "$ROOT" status --short >&2
  echo "Commit or stash those changes, then run the updater again." >&2
  exit 1
fi

echo "Checking GitHub for Pi Space updates..."
git -C "$ROOT" fetch --quiet --prune "$REMOTE" "$BRANCH"
LOCAL_REV="$(git -C "$ROOT" rev-parse HEAD)"
REMOTE_REV="$(git -C "$ROOT" rev-parse "$REMOTE/$BRANCH")"

if [[ "$LOCAL_REV" == "$REMOTE_REV" ]]; then
  echo "Pi Space is already up to date."
  exit 0
fi

if ! git -C "$ROOT" merge-base --is-ancestor "$LOCAL_REV" "$REMOTE_REV"; then
  echo "Update stopped because local and GitHub history have diverged." >&2
  echo "Resolve the branch manually; the updater will never reset local commits." >&2
  exit 1
fi

CURRENT="$(git -C "$ROOT" describe --always --tags "$LOCAL_REV")"
AVAILABLE="$(git -C "$ROOT" describe --always --tags "$REMOTE_REV")"
echo "Update available: $CURRENT -> $AVAILABLE"
((CHECK_ONLY)) && exit 0

INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
if [[ "$WAKE_MODE" == "auto" ]]; then
  if [[ -d "$INSTALL_DIR/Wake Pi Listener.app" || -f "$HOME/Library/LaunchAgents/com.olivergreen.wakepi.plist" ]]; then
    WAKE_MODE="yes"
  else
    WAKE_MODE="no"
  fi
fi

git -C "$ROOT" pull --ff-only "$REMOTE" "$BRANCH"

INSTALL_ARGS=()
[[ "$WAKE_MODE" == "yes" ]] && INSTALL_ARGS+=(--with-wake-listener)
((OPEN_AFTER == 0)) && INSTALL_ARGS+=(--no-open)
"$ROOT/scripts/install.sh" "${INSTALL_ARGS[@]}"

NEW_REV="$(git -C "$ROOT" describe --always --tags HEAD)"
echo "Pi Space updated successfully to $NEW_REV."

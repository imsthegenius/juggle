#!/bin/bash
# Run Juggle's visual diagnostics through the stably signed app bundle.
#
# Do not use `swift run Juggle --notch-live ...` for routine visual QA. SwiftPM
# launches an ad-hoc-signed executable whose cdhash changes on every rebuild; if
# that process touches Desktop/Documents projects, macOS TCC records a new code
# identity and folder access gets polluted. This script ships the signed bundle
# first, then runs the diagnostic with an isolated Application Support store.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Applications/Juggle.app"
BIN="$APP/Contents/MacOS/Juggle"

usage() {
  cat >&2 <<'USAGE'
Usage:
  scripts/juggle-diagnostic.sh --notch-live <dir>
  scripts/juggle-diagnostic.sh --notch-empty <dir>
  scripts/juggle-diagnostic.sh --notch-shot <dir>
  scripts/juggle-diagnostic.sh --notch-click-test <dir>
  scripts/juggle-diagnostic.sh --project-open-shot <dir>
  scripts/juggle-diagnostic.sh --launch-surface-shot <dir>
  scripts/juggle-diagnostic.sh --launch-home-shot <dir>
  scripts/juggle-diagnostic.sh --control-panel-shot <dir>
  scripts/juggle-diagnostic.sh --onboarding-shots <dir>
  scripts/juggle-diagnostic.sh --terminal-window-shot <repo> <dir>

Builds and signs ~/Applications/Juggle.app, then runs the diagnostic from that
stable code identity with JUGGLE_APP_SUPPORT_DIR pointed at a temp store.
USAGE
}

if [ $# -lt 2 ]; then
  usage
  exit 2
fi

case "$1" in
  --notch-live|--notch-empty|--notch-shot|--notch-click-test|\
  --project-open-shot|--launch-surface-shot|--launch-home-shot|--control-panel-shot|\
  --onboarding-shots|--terminal-window-shot)
    ;;
  *)
    usage
    exit 2
    ;;
esac

"$REPO_ROOT/scripts/juggle-ship.sh" >&2

if [ ! -x "$BIN" ]; then
  echo "ERROR: signed app binary not found: $BIN" >&2
  exit 1
fi

SUPPORT_DIR="${JUGGLE_DIAGNOSTIC_APP_SUPPORT_DIR:-$(mktemp -d /tmp/juggle-diagnostic-support.XXXXXX)}"
echo "==> diagnostic app support: $SUPPORT_DIR" >&2

if [ "$1" = "--terminal-window-shot" ]; then
  if [ $# -lt 3 ]; then
    usage
    exit 2
  fi
  JUGGLE_APP_SUPPORT_DIR="$SUPPORT_DIR" "$BIN" "$2" --qa-shot "$3"
else
  JUGGLE_APP_SUPPORT_DIR="$SUPPORT_DIR" "$BIN" "$@"
fi

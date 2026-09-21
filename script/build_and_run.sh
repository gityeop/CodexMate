#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if pgrep -x CodexMate >/dev/null; then
  pkill -x CodexMate
fi

CONFIGURATION=debug ALLOW_ADHOC_SIGNING=1 DIST_DIR="$ROOT_DIR/dist/dev" \
  "$ROOT_DIR/scripts/package_app.sh"
/usr/bin/open -n "$ROOT_DIR/dist/dev/CodexMate.app"

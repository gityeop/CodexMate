#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/dist/CodextensionMenubar.app}"
ZIP_PATH="${APP_PATH:r}.zip"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App not found at $APP_PATH" >&2
  exit 1
fi

if [[ -z "${APPLE_NOTARY_PROFILE:-}" ]]; then
  echo "Set APPLE_NOTARY_PROFILE to a notarytool keychain profile." >&2
  exit 1
fi

ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$APPLE_NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_PATH"

echo "Notarized app: $APP_PATH"

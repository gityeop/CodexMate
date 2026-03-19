#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CodexMate"
APP_PATH="${APP_PATH:-$ROOT_DIR/dist/$APP_NAME.app}"
RELEASE_DIR="${RELEASE_DIR:-$ROOT_DIR/dist/release}"
SPARKLE_BIN_DIR="${SPARKLE_BIN_DIR:-$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin}"
GENERATE_KEYS_BIN="$SPARKLE_BIN_DIR/generate_keys"
GENERATE_APPCAST_BIN="$SPARKLE_BIN_DIR/generate_appcast"
SPARKLE_KEYCHAIN_ACCOUNT="${SPARKLE_KEYCHAIN_ACCOUNT:-ed25519}"

require_env() {
  local name="$1"
  if [[ -z "${(P)name:-}" ]]; then
    echo "Set $name." >&2
    exit 1
  fi
}

ensure_executable() {
  local path="$1"
  if [[ ! -x "$path" ]]; then
    echo "Expected executable at $path." >&2
    exit 1
  fi
}

APP_VERSION="${APP_VERSION:-}"
APP_SHORT_VERSION="${APP_SHORT_VERSION:-}"
SPARKLE_APPCAST_URL="${SPARKLE_APPCAST_URL:-}"
SPARKLE_DOWNLOAD_URL_PREFIX="${SPARKLE_DOWNLOAD_URL_PREFIX:-}"
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}"
SPARKLE_PRIVATE_KEY_FILE="${SPARKLE_PRIVATE_KEY_FILE:-}"
RELEASE_NOTES_FILE="${RELEASE_NOTES_FILE:-}"
RELEASE_LINK="${RELEASE_LINK:-}"
ALLOW_ADHOC_SIGNING="${ALLOW_ADHOC_SIGNING:-0}"
SKIP_NOTARIZATION="${SKIP_NOTARIZATION:-0}"

require_env APP_VERSION
require_env APP_SHORT_VERSION
require_env SPARKLE_APPCAST_URL
require_env RELEASE_NOTES_FILE

if [[ ! -f "$RELEASE_NOTES_FILE" ]]; then
  echo "Release notes file not found at $RELEASE_NOTES_FILE." >&2
  exit 1
fi

RELEASE_NOTES_EXTENSION="${RELEASE_NOTES_FILE:e:l}"
if [[ "$RELEASE_NOTES_EXTENSION" != "html" && "$RELEASE_NOTES_EXTENSION" != "md" && "$RELEASE_NOTES_EXTENSION" != "txt" ]]; then
  echo "Release notes file must end in .html, .md, or .txt." >&2
  exit 1
fi

if [[ -z "${APPLE_SIGN_IDENTITY:-}" && "$ALLOW_ADHOC_SIGNING" != "1" ]]; then
  echo "Set APPLE_SIGN_IDENTITY for a release build. Use ALLOW_ADHOC_SIGNING=1 only for local dry runs." >&2
  exit 1
fi

if [[ -z "${APPLE_NOTARY_PROFILE:-}" && "$SKIP_NOTARIZATION" != "1" ]]; then
  echo "Set APPLE_NOTARY_PROFILE or pass SKIP_NOTARIZATION=1." >&2
  exit 1
fi

ensure_executable "$GENERATE_APPCAST_BIN"

if [[ -z "$SPARKLE_PUBLIC_KEY" ]]; then
  if [[ -n "$SPARKLE_PRIVATE_KEY_FILE" ]]; then
    echo "Set SPARKLE_PUBLIC_KEY when using SPARKLE_PRIVATE_KEY_FILE." >&2
    exit 1
  fi

  ensure_executable "$GENERATE_KEYS_BIN"
  SPARKLE_PUBLIC_KEY="$("$GENERATE_KEYS_BIN" --account "$SPARKLE_KEYCHAIN_ACCOUNT" -p)"
  if [[ -z "$SPARKLE_PUBLIC_KEY" ]]; then
    echo "Unable to resolve SPARKLE_PUBLIC_KEY from the Sparkle keychain account." >&2
    exit 1
  fi
fi

if [[ -n "$SPARKLE_PRIVATE_KEY_FILE" && ! -f "$SPARKLE_PRIVATE_KEY_FILE" ]]; then
  echo "Sparkle private key file not found at $SPARKLE_PRIVATE_KEY_FILE." >&2
  exit 1
fi

if [[ -z "$SPARKLE_DOWNLOAD_URL_PREFIX" ]]; then
  SPARKLE_DOWNLOAD_URL_PREFIX="${SPARKLE_APPCAST_URL%/*}"
fi

if [[ "$SPARKLE_DOWNLOAD_URL_PREFIX" != */ ]]; then
  SPARKLE_DOWNLOAD_URL_PREFIX="${SPARKLE_DOWNLOAD_URL_PREFIX}/"
fi

APPCAST_FILENAME="${SPARKLE_APPCAST_URL##*/}"
ARCHIVE_BASENAME="${APP_NAME}-${APP_SHORT_VERSION}"
ARCHIVE_PATH="$RELEASE_DIR/$ARCHIVE_BASENAME.zip"
RELEASE_NOTES_DEST="$RELEASE_DIR/$ARCHIVE_BASENAME.$RELEASE_NOTES_EXTENSION"
APPCAST_PATH="$RELEASE_DIR/$APPCAST_FILENAME"

mkdir -p "$RELEASE_DIR"

APP_VERSION="$APP_VERSION" \
APP_SHORT_VERSION="$APP_SHORT_VERSION" \
SPARKLE_FEED_URL="$SPARKLE_APPCAST_URL" \
SPARKLE_PUBLIC_KEY="$SPARKLE_PUBLIC_KEY" \
"$ROOT_DIR/scripts/package_app.sh"

if [[ "$SKIP_NOTARIZATION" == "1" ]]; then
  echo "Skipping notarization."
else
  APPLE_NOTARY_PROFILE="$APPLE_NOTARY_PROFILE" "$ROOT_DIR/scripts/notarize_app.sh" "$APP_PATH"
fi

rm -f "$ARCHIVE_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ARCHIVE_PATH"

cp "$RELEASE_NOTES_FILE" "$RELEASE_NOTES_DEST"

generate_appcast_args=(
  "$GENERATE_APPCAST_BIN"
  "--download-url-prefix" "$SPARKLE_DOWNLOAD_URL_PREFIX"
  "--embed-release-notes"
  "--versions" "$APP_VERSION"
  "-o" "$APPCAST_PATH"
)

if [[ -n "$RELEASE_LINK" ]]; then
  generate_appcast_args+=("--link" "$RELEASE_LINK")
fi

if [[ -n "$SPARKLE_PRIVATE_KEY_FILE" ]]; then
  generate_appcast_args+=("--ed-key-file" "$SPARKLE_PRIVATE_KEY_FILE")
else
  generate_appcast_args+=("--account" "$SPARKLE_KEYCHAIN_ACCOUNT")
fi

generate_appcast_args+=("$RELEASE_DIR")
"${generate_appcast_args[@]}"

if ! grep -q "<sparkle:version>${APP_VERSION}</sparkle:version>" "$APPCAST_PATH"; then
  echo "Generated appcast does not contain version $APP_VERSION." >&2
  exit 1
fi

echo "Release archive: $ARCHIVE_PATH"
echo "Release notes: $RELEASE_NOTES_DEST"
echo "Appcast: $APPCAST_PATH"

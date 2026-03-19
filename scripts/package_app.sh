#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CodexMate"
CONFIGURATION="${CONFIGURATION:-release}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
PLIST_TEMPLATE="$ROOT_DIR/Packaging/CodexMate-Info.plist.template"
APP_ICON_SOURCE="${APP_ICON_SOURCE:-$ROOT_DIR/Packaging/$APP_NAME.png}"
APP_ICON_FILE="${APP_ICON_FILE:-$APP_NAME.icns}"
APPLE_KEYCHAIN_PATH="${APPLE_KEYCHAIN_PATH:-$(security login-keychain | tr -d '"')}"
APPLE_KEYCHAIN_PASSWORD="${APPLE_KEYCHAIN_PASSWORD:-}"
APPLE_KEYCHAIN_UNLOCK_TIMEOUT="${APPLE_KEYCHAIN_UNLOCK_TIMEOUT:-21600}"

BUNDLE_IDENTIFIER="${CODEXMATE_BUNDLE_ID:-${CODEXTENSION_BUNDLE_ID:-com.imsangyeob.codexmate}}"
APP_VERSION="${APP_VERSION:-$(git -C "$ROOT_DIR" rev-parse --short HEAD)}"
APP_SHORT_VERSION="${APP_SHORT_VERSION:-$APP_VERSION}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://example.com/appcast.xml}"
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}"

typeset -a CODESIGN_KEYCHAIN_ARGS
if [[ -n "$APPLE_KEYCHAIN_PATH" ]]; then
  CODESIGN_KEYCHAIN_ARGS=(--keychain "$APPLE_KEYCHAIN_PATH")
else
  CODESIGN_KEYCHAIN_ARGS=()
fi

sign_with_identity() {
  local target="$1"
  local identity="$2"
  shift 2
  codesign --force --sign "$identity" "${CODESIGN_KEYCHAIN_ARGS[@]}" "$@" "$target"
}

prepare_signing_keychain() {
  [[ -n "${APPLE_SIGN_IDENTITY:-}" ]] || return

  if [[ -z "$APPLE_KEYCHAIN_PASSWORD" ]]; then
    echo "Signing without APPLE_KEYCHAIN_PASSWORD may trigger repeated Keychain prompts." >&2
    return
  fi

  security unlock-keychain -p "$APPLE_KEYCHAIN_PASSWORD" "$APPLE_KEYCHAIN_PATH"
  security set-keychain-settings -lut "$APPLE_KEYCHAIN_UNLOCK_TIMEOUT" "$APPLE_KEYCHAIN_PATH" >/dev/null 2>&1 || true
  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$APPLE_KEYCHAIN_PASSWORD" \
    "$APPLE_KEYCHAIN_PATH" >/dev/null
}

create_app_icon() {
  local source="$1"
  local icon_file="$2"
  local iconset_dir="$DIST_DIR/${APP_NAME}.iconset"
  local icns_path="$RESOURCES_DIR/$icon_file"
  local size doubled

  if [[ ! -f "$source" ]]; then
    echo "App icon source not found at $source" >&2
    exit 1
  fi

  if ! command -v iconutil >/dev/null 2>&1; then
    echo "iconutil is required to package the app icon." >&2
    exit 1
  fi

  rm -rf "$iconset_dir"
  mkdir -p "$iconset_dir"

  for size in 16 32 128 256 512; do
    doubled=$((size * 2))
    sips -z "$size" "$size" "$source" --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
    sips -z "$doubled" "$doubled" "$source" --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
  done

  iconutil -c icns "$iconset_dir" -o "$icns_path"
  rm -rf "$iconset_dir"
}

mkdir -p "$DIST_DIR"

swift build -c "$CONFIGURATION" --product "$APP_NAME"
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
EXECUTABLE_PATH="$BIN_DIR/$APP_NAME"

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "Expected executable at $EXECUTABLE_PATH" >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"

cp "$EXECUTABLE_PATH" "$MACOS_DIR/$APP_NAME"

install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/$APP_NAME" 2>/dev/null || true

RESOURCE_BUNDLE_PATH="$(find "$BIN_DIR" -maxdepth 1 -name "${APP_NAME}_*.bundle" -print -quit || true)"
if [[ -n "$RESOURCE_BUNDLE_PATH" ]]; then
  cp -R "$RESOURCE_BUNDLE_PATH" "$RESOURCES_DIR/"
fi

create_app_icon "$APP_ICON_SOURCE" "$APP_ICON_FILE"

SPARKLE_FRAMEWORK_PATH="$(find "$ROOT_DIR/.build" -path '*Sparkle.framework' -type d -print -quit || true)"
if [[ -n "$SPARKLE_FRAMEWORK_PATH" ]]; then
  cp -R "$SPARKLE_FRAMEWORK_PATH" "$FRAMEWORKS_DIR/"
fi

sed \
  -e "s#__EXECUTABLE_NAME__#$APP_NAME#g" \
  -e "s#__BUNDLE_IDENTIFIER__#$BUNDLE_IDENTIFIER#g" \
  -e "s#__APP_SHORT_VERSION__#$APP_SHORT_VERSION#g" \
  -e "s#__APP_VERSION__#$APP_VERSION#g" \
  -e "s#__SPARKLE_FEED_URL__#$SPARKLE_FEED_URL#g" \
  -e "s#__SPARKLE_PUBLIC_KEY__#$SPARKLE_PUBLIC_KEY#g" \
  -e "s#__ICON_FILE__#$APP_ICON_FILE#g" \
  "$PLIST_TEMPLATE" > "$CONTENTS_DIR/Info.plist"

SIGN_IDENTITY="${APPLE_SIGN_IDENTITY:--}"

prepare_signing_keychain

if [[ -n "${APPLE_SIGN_IDENTITY:-}" ]]; then
  if [[ -d "$FRAMEWORKS_DIR/Sparkle.framework" ]]; then
    SPARKLE_CURRENT_DIR="$FRAMEWORKS_DIR/Sparkle.framework/Versions/Current"

    if [[ -d "$SPARKLE_CURRENT_DIR/XPCServices/Downloader.xpc" ]]; then
      sign_with_identity "$SPARKLE_CURRENT_DIR/XPCServices/Downloader.xpc" "$APPLE_SIGN_IDENTITY" --options runtime --timestamp
    fi

    if [[ -d "$SPARKLE_CURRENT_DIR/XPCServices/Installer.xpc" ]]; then
      sign_with_identity "$SPARKLE_CURRENT_DIR/XPCServices/Installer.xpc" "$APPLE_SIGN_IDENTITY" --options runtime --timestamp
    fi

    if [[ -d "$SPARKLE_CURRENT_DIR/Updater.app" ]]; then
      sign_with_identity "$SPARKLE_CURRENT_DIR/Updater.app" "$APPLE_SIGN_IDENTITY" --options runtime --timestamp
    fi

    if [[ -f "$SPARKLE_CURRENT_DIR/Autoupdate" ]]; then
      sign_with_identity "$SPARKLE_CURRENT_DIR/Autoupdate" "$APPLE_SIGN_IDENTITY" --options runtime --timestamp
    fi

    sign_with_identity "$FRAMEWORKS_DIR/Sparkle.framework" "$APPLE_SIGN_IDENTITY" --options runtime --timestamp
  fi
  sign_with_identity "$MACOS_DIR/$APP_NAME" "$APPLE_SIGN_IDENTITY" --options runtime --timestamp
  sign_with_identity "$APP_DIR" "$APPLE_SIGN_IDENTITY" --options runtime --timestamp
else
  codesign --force --sign "$SIGN_IDENTITY" "${CODESIGN_KEYCHAIN_ARGS[@]}" "$MACOS_DIR/$APP_NAME"
  codesign --force --deep --sign - "${CODESIGN_KEYCHAIN_ARGS[@]}" "$APP_DIR"
fi

echo "Packaged app: $APP_DIR"

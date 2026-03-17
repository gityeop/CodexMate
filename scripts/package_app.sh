#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CodextensionMenubar"
CONFIGURATION="${CONFIGURATION:-release}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
PLIST_TEMPLATE="$ROOT_DIR/Packaging/CodextensionMenubar-Info.plist.template"

BUNDLE_IDENTIFIER="${CODEXTENSION_BUNDLE_ID:-com.imsangyeob.codextension-menubar}"
APP_VERSION="${APP_VERSION:-$(git -C "$ROOT_DIR" rev-parse --short HEAD)}"
APP_SHORT_VERSION="${APP_SHORT_VERSION:-$APP_VERSION}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://example.com/appcast.xml}"
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}"

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
  "$PLIST_TEMPLATE" > "$CONTENTS_DIR/Info.plist"

SIGN_IDENTITY="${APPLE_SIGN_IDENTITY:--}"

codesign --force --sign "$SIGN_IDENTITY" "$MACOS_DIR/$APP_NAME"

if [[ -d "$FRAMEWORKS_DIR/Sparkle.framework" ]]; then
  codesign --force --options runtime --sign "$SIGN_IDENTITY" "$FRAMEWORKS_DIR/Sparkle.framework"
fi

if [[ -n "${APPLE_SIGN_IDENTITY:-}" ]]; then
  if [[ -d "$FRAMEWORKS_DIR/Sparkle.framework" ]]; then
    codesign --force --options runtime --sign "$APPLE_SIGN_IDENTITY" "$FRAMEWORKS_DIR/Sparkle.framework"
  fi
  codesign --force --options runtime --sign "$APPLE_SIGN_IDENTITY" "$APP_DIR"
else
  codesign --force --deep --sign - "$APP_DIR"
fi

echo "Packaged app: $APP_DIR"

#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CodexQuickSwitch"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
DMG_STAGE_DIR="$ROOT_DIR/dist/dmg-root"
DMG_PATH="$ROOT_DIR/dist/$APP_NAME.dmg"

cd "$ROOT_DIR"

./scripts/build-app.sh

rm -rf "$DMG_STAGE_DIR" "$DMG_PATH"
mkdir -p "$DMG_STAGE_DIR"

cp -R "$APP_DIR" "$DMG_STAGE_DIR/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE_DIR/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

echo "Built dmg: $DMG_PATH"

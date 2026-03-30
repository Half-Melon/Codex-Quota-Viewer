#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="${SESSION_MANAGER_VENDOR_DIR:-$ROOT_DIR/Vendor/CodexMM}"
STAGING_DIR="${SESSION_MANAGER_STAGING_DIR:-$ROOT_DIR/.build/session-manager}"
OUTPUT_DIR="${1:-}"

if [[ -z "$OUTPUT_DIR" ]]; then
  echo "usage: $0 <session-manager-output-dir>" >&2
  exit 1
fi

if [[ ! -d "$VENDOR_DIR" ]]; then
  echo "error: vendored CodexMM directory not found: $VENDOR_DIR" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "error: node is required to build the bundled session manager." >&2
  exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "error: npm is required to build the bundled session manager." >&2
  exit 1
fi

NODE_BIN="$(node -p 'process.execPath')"
STAGING_SOURCE_DIR="$STAGING_DIR/source"
APP_OUTPUT_DIR="$OUTPUT_DIR/App"
RUNTIME_OUTPUT_DIR="$OUTPUT_DIR/Runtime"

rm -rf "$STAGING_DIR" "$OUTPUT_DIR"
mkdir -p "$STAGING_SOURCE_DIR" "$APP_OUTPUT_DIR" "$RUNTIME_OUTPUT_DIR/bin"

rsync -a \
  --delete \
  --exclude '.git' \
  --exclude 'node_modules' \
  --exclude 'dist' \
  --exclude '.DS_Store' \
  "$VENDOR_DIR"/ "$STAGING_SOURCE_DIR"/

cd "$STAGING_SOURCE_DIR"
npm ci
npm run build
npm prune --omit=dev

mkdir -p "$APP_OUTPUT_DIR/dist" "$APP_OUTPUT_DIR/node_modules"
rsync -a --delete dist/ "$APP_OUTPUT_DIR/dist/"
rsync -a --delete node_modules/ "$APP_OUTPUT_DIR/node_modules/"
cp package.json "$APP_OUTPUT_DIR/package.json"
cp package-lock.json "$APP_OUTPUT_DIR/package-lock.json"
cp "$NODE_BIN" "$RUNTIME_OUTPUT_DIR/bin/node"
chmod +x "$RUNTIME_OUTPUT_DIR/bin/node"

echo "Bundled session manager prepared at: $OUTPUT_DIR"

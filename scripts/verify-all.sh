#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/Vendor/CodexMM"

echo "==> swift test"
swift test --package-path "$ROOT_DIR"

echo "==> npm run typecheck"
(cd "$VENDOR_DIR" && npm run typecheck)

echo "==> npm run lint"
(cd "$VENDOR_DIR" && npm run lint)

echo "==> npm run test"
(cd "$VENDOR_DIR" && npm run test)

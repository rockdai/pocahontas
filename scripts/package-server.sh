#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/.build"
STAGING="$(mktemp -d "$ROOT/.build/server-package.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
cp "$ROOT/server/package.json" "$ROOT/server/package-lock.json" "$ROOT/server/fc.js" "$STAGING/"
cp -R "$ROOT/server/src" "$STAGING/src"
cd "$STAGING"
npm ci --omit=dev --ignore-scripts
node --input-type=module -e 'await import("./fc.js")'
zip -qr artifact.zip fc.js package.json package-lock.json src node_modules
mv artifact.zip "$ROOT/.build/pocahontas-server.zip"
echo "FC package: $ROOT/.build/pocahontas-server.zip"

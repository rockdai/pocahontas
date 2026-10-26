#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
xcodegen generate
DEST=pocahontas.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
mkdir -p "$DEST"
cp Packages/PocahontasKit/Package.resolved "$DEST/Package.resolved"

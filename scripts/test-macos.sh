#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PYTHON="${PYTHON:-$ROOT/.build/test-venv/bin/python}"
[[ -x "$PYTHON" ]] || { echo 'Create .build/test-venv and install scripts/requirements-test.txt first.' >&2; exit 1; }
RUN_DIR="$(mktemp -d "$ROOT/.build/macos-tests.XXXXXX")"
# A new loopback endpoint exercises first-use trust without deleting any saved pins.
PORT="$("$PYTHON" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
"$PYTHON" scripts/ssh-fixture.py --port "$PORT" --state-dir "$RUN_DIR/fixture" > "$RUN_DIR/fixture.log" 2>&1 &
FIXTURE_PID=$!
trap 'kill "$FIXTURE_PID" 2>/dev/null || true; wait "$FIXTURE_PID" 2>/dev/null || true' EXIT
for attempt in {1..50}; do
  kill -0 "$FIXTURE_PID" 2>/dev/null || { cat "$RUN_DIR/fixture.log"; exit 1; }
  if rg -q 'Fixture listening' "$RUN_DIR/fixture.log"; then break; fi
  sleep 0.1
done
rg -q 'Fixture listening' "$RUN_DIR/fixture.log"
scripts/generate-project.sh
echo "Native Mac tests and screenshots; log: $RUN_DIR/test.log"
xcodebuild -project pocahontas.xcodeproj -scheme pocahontas-macOS \
  -destination 'platform=macOS' -derivedDataPath .build/DerivedData \
  -resultBundlePath "$RUN_DIR/macOS.xcresult" -parallel-testing-enabled NO \
  -disableAutomaticPackageResolution "POCAHONTAS_MAC_TEST_PORT=$PORT" test > "$RUN_DIR/test.log" 2>&1
"$PYTHON" scripts/export-screenshots.py "$RUN_DIR/macOS.xcresult" docs/screenshots/macos-m0 \
  --count 16 --desktop
echo "Mac screenshots exported; results: $RUN_DIR/macOS.xcresult"

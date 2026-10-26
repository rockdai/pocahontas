#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PYTHON="${PYTHON:-$ROOT/.build/test-venv/bin/python}"
RUNTIME="${SIMULATOR_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-26-5}"
[[ -x "$PYTHON" ]] || { echo 'Create .build/test-venv and install scripts/requirements-test.txt first.' >&2; exit 1; }
RUN_DIR="$(mktemp -d "$ROOT/.build/screenshots.XXXXXX")"
SIMULATOR_ID=""
FIXTURE_PID=""
cleanup() {
  if [[ -n "$SIMULATOR_ID" ]]; then
    xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true
    xcrun simctl delete "$SIMULATOR_ID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$FIXTURE_PID" ]]; then
    kill "$FIXTURE_PID" 2>/dev/null || true
    wait "$FIXTURE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT
scripts/generate-project.sh
"$PYTHON" scripts/ssh-fixture.py --port 62224 --state-dir "$RUN_DIR/fixture" > "$RUN_DIR/fixture.log" 2>&1 &
FIXTURE_PID=$!
for attempt in {1..50}; do
  kill -0 "$FIXTURE_PID" 2>/dev/null || { cat "$RUN_DIR/fixture.log"; exit 1; }
  if rg -q 'Fixture listening' "$RUN_DIR/fixture.log"; then break; fi
  sleep 0.1
done
rg -q 'Fixture listening' "$RUN_DIR/fixture.log"

for DEVICE in iphone ipad; do
  case "$DEVICE" in
    iphone) DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro ;;
    ipad) DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-16GB ;;
  esac
  # A fresh simulator keeps first-use trust, Files and the clipboard reproducible.
  SIMULATOR_ID="$(xcrun simctl create "pocahontas-screenshots-$DEVICE" "$DEVICE_TYPE" "$RUNTIME")"
  xcrun simctl boot "$SIMULATOR_ID"
  xcrun simctl bootstatus "$SIMULATOR_ID" -b > "$RUN_DIR/$DEVICE-boot.log"
  xcrun simctl status_bar "$SIMULATOR_ID" override --time '9:41' \
    --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
  echo "Capturing $DEVICE; log: $RUN_DIR/$DEVICE.log"
  xcodebuild -project pocahontas.xcodeproj -scheme screenshots \
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
    -derivedDataPath .build/DerivedData -resultBundlePath "$RUN_DIR/$DEVICE.xcresult" \
    -parallel-testing-enabled NO -disableAutomaticPackageResolution test > "$RUN_DIR/$DEVICE.log" 2>&1
  "$PYTHON" scripts/export-screenshots.py "$RUN_DIR/$DEVICE.xcresult" "docs/screenshots/ios-m0/$DEVICE"
  xcrun simctl shutdown "$SIMULATOR_ID"
  xcrun simctl delete "$SIMULATOR_ID"
  SIMULATOR_ID=""
done
echo "Screenshots saved in docs/screenshots/ios-m0; test results: $RUN_DIR"

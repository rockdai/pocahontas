#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p .build
RUN_DIR="$(mktemp -d "$ROOT/.build/account-ui.XXXXXX")"
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
node server/test/fixture.js "$RUN_DIR/url" > "$RUN_DIR/fixture.log" 2>&1 &
FIXTURE_PID=$!
for attempt in {1..100}; do
  kill -0 "$FIXTURE_PID" 2>/dev/null || { cat "$RUN_DIR/fixture.log"; exit 1; }
  [[ -s "$RUN_DIR/url" ]] && break
  sleep 0.1
done
[[ -s "$RUN_DIR/url" ]]
ACCOUNT_URL="$(cat "$RUN_DIR/url")"
scripts/generate-project.sh
for DEVICE in ${ACCOUNT_TEST_DEVICES:-iphone ipad macos}; do
  EXPORT_OPTIONS=(--count 9)
  if [[ "$DEVICE" == macos ]]; then
    SCHEME=pocahontas-macOS
    DESTINATION=platform=macOS
    TARGET=PocahontasMacUITests
    STORAGE_TARGET=PocahontasMacTests
    EXPORT_OPTIONS=(--count 9 --desktop)
  else
    if [[ "$DEVICE" == iphone ]]; then
      DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro
    else
      DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-16GB
    fi
    SIMULATOR_ID="$(xcrun simctl create "pocahontas-account-$DEVICE" "$DEVICE_TYPE" "${SIMULATOR_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-26-5}")"
    xcrun simctl boot "$SIMULATOR_ID"
    xcrun simctl bootstatus "$SIMULATOR_ID" -b > "$RUN_DIR/$DEVICE-boot.log"
    xcrun simctl ui "$SIMULATOR_ID" appearance dark
    xcrun simctl status_bar "$SIMULATOR_ID" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
    SCHEME=library-screenshots
    TARGET=PocahontasLibraryScreenshotTests
    STORAGE_TARGET=PocahontasAppTests
    DESTINATION="platform=iOS Simulator,id=$SIMULATOR_ID"
  fi
  echo "Account UI: $DEVICE; log: $RUN_DIR/$DEVICE.log"
  xcodebuild -project pocahontas.xcodeproj -scheme "$SCHEME" -destination "$DESTINATION" \
    -derivedDataPath .build/DerivedData -resultBundlePath "$RUN_DIR/$DEVICE.xcresult" \
    -parallel-testing-enabled NO -disableAutomaticPackageResolution \
    "POCAHONTAS_SERVER_URL=$ACCOUNT_URL" "-only-testing:$TARGET/AccountUITests" \
    "-only-testing:$STORAGE_TARGET/AccountStorageTests" test > "$RUN_DIR/$DEVICE.log" 2>&1
  python3 scripts/export-screenshots.py "$RUN_DIR/$DEVICE.xcresult" "docs/screenshots/account/$DEVICE" "${EXPORT_OPTIONS[@]}"
  if [[ -n "$SIMULATOR_ID" ]]; then
    xcrun simctl shutdown "$SIMULATOR_ID"
    xcrun simctl delete "$SIMULATOR_ID"
    SIMULATOR_ID=""
  fi
done
echo "Account screenshots and real Keychain checks complete: $RUN_DIR"

#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PYTHON="${PYTHON:-$ROOT/.build/test-venv/bin/python}"
[[ -x "$PYTHON" ]] || { echo 'Create .build/test-venv and install scripts/requirements-test.txt first.' >&2; exit 1; }
RUNTIME="$(xcrun simctl list runtimes available -j | jq -r '[.runtimes[] | select(.platform == "iOS")] | last | .identifier')"
RUN_DIR="$(mktemp -d "$ROOT/.build/native-tests.XXXXXX")"
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

run_tests() {
  local name="$1"
  shift
  echo "$name tests; log: $RUN_DIR/$name.log"
  if ! xcodebuild -project pocahontas.xcodeproj -derivedDataPath .build/DerivedData \
    -resultBundlePath "$RUN_DIR/$name.xcresult" -parallel-testing-enabled NO \
    -disableAutomaticPackageResolution "$@" test > "$RUN_DIR/$name.log" 2>&1; then
    tail -n 80 "$RUN_DIR/$name.log"
    return 1
  fi
  local summary
  summary="$(xcrun xcresulttool get test-results summary --path "$RUN_DIR/$name.xcresult" |
    jq -c '{result, passedTests, failedTests, skippedTests}')"
  echo "$summary"
  # A skip here means the fixture never reached the test, not that it passed.
  jq -e '.skippedTests == 0' <<< "$summary" > /dev/null
}

# A new loopback endpoint exercises first-use trust without deleting any saved pins.
PORT="$("$PYTHON" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
"$PYTHON" scripts/ssh-fixture.py --port "$PORT" --state-dir "$RUN_DIR/fixture" > "$RUN_DIR/fixture.log" 2>&1 &
FIXTURE_PID=$!
for _ in {1..50}; do
  kill -0 "$FIXTURE_PID" 2>/dev/null || { cat "$RUN_DIR/fixture.log"; exit 1; }
  if grep -q 'Fixture listening' "$RUN_DIR/fixture.log"; then break; fi
  sleep 0.1
done
grep -q 'Fixture listening' "$RUN_DIR/fixture.log"
scripts/generate-project.sh

# A fresh simulator holds no host pin from an earlier fixture key.
SIMULATOR_ID="$(xcrun simctl create pocahontas-native-tests com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro "$RUNTIME")"
TEST_RUNNER_POCAHONTAS_SESSION_TEST_PORT="$PORT" run_tests iOS -scheme pocahontas \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID"
run_tests macOS -scheme pocahontas-macOS -destination 'platform=macOS' \
  "POCAHONTAS_MAC_TEST_PORT=$PORT" -only-testing:PocahontasMacTests

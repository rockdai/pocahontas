#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p .build
RUN_DIR="$(mktemp -d "$ROOT/.build/account-tests.XXXXXX")"
node server/test/fixture.js "$RUN_DIR/url" > "$RUN_DIR/fixture.log" 2>&1 &
FIXTURE_PID=$!
trap 'kill "$FIXTURE_PID" 2>/dev/null || true; wait "$FIXTURE_PID" 2>/dev/null || true' EXIT
for attempt in {1..100}; do
  kill -0 "$FIXTURE_PID" 2>/dev/null || { cat "$RUN_DIR/fixture.log"; exit 1; }
  if [[ -s "$RUN_DIR/url" ]]; then break; fi
  sleep 0.1
done
[[ -s "$RUN_DIR/url" ]] || { cat "$RUN_DIR/fixture.log"; exit 1; }
POCAHONTAS_ACCOUNT_TEST_URL="$(cat "$RUN_DIR/url")" \
  swift test --package-path Packages/PocahontasKit -j 4 --filter Account

#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="${PYTHON:-$ROOT/.build/test-venv/bin/python}"
[[ -x "$PYTHON" ]] || { echo 'Create .build/test-venv and install scripts/requirements-test.txt first.' >&2; exit 1; }
PORT="${POCAHONTAS_SSH_TEST_PORT:-62223}"
"$PYTHON" "$ROOT/scripts/ssh-fixture.py" --port "$PORT" --state-dir "$ROOT/.build/ssh-fixture" > "$ROOT/.build/ssh-fixture.log" 2>&1 &
FIXTURE_PID=$!
trap 'kill "$FIXTURE_PID" 2>/dev/null || true; wait "$FIXTURE_PID" 2>/dev/null || true' EXIT
for attempt in {1..50}; do
  kill -0 "$FIXTURE_PID" 2>/dev/null || { cat "$ROOT/.build/ssh-fixture.log"; exit 1; }
  if rg -q 'Fixture listening' "$ROOT/.build/ssh-fixture.log"; then break; fi
  sleep 0.1
done
cd "$ROOT/Packages/PocahontasKit"
POCAHONTAS_SSH_TEST_PORT="$PORT" swift test -j 4

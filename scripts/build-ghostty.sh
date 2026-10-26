#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$ROOT/vendor/ghostty"
ZIG="${ZIG:-/opt/homebrew/opt/zig@0.15/bin/zig}"
EXPECTED=7fb9e90363a431d15a67a22ff661e33c1be59060
[[ -x "$ZIG" ]] || { echo 'Install zig@0.15 or set ZIG to its executable.' >&2; exit 1; }
[[ "$(git -C "$ENGINE" rev-parse HEAD)" == "$EXPECTED" ]] || { echo 'Unexpected Ghostty revision.' >&2; exit 1; }
[[ "$("$ZIG" version)" == 0.15.2 ]] || { echo 'This build requires Zig 0.15.2.' >&2; exit 1; }
export ZIG_GLOBAL_CACHE_DIR="$ROOT/.cache/zig"
mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
if [[ -n "${ZIG_CACHE_SEED:-}" && ! -d "$ZIG_GLOBAL_CACHE_DIR/p" ]]; then
  cp -R "$ZIG_CACHE_SEED/p" "$ZIG_GLOBAL_CACHE_DIR/p"
fi
cd "$ENGINE"
"$ZIG" build --fetch=all
python3 - "$ZIG_GLOBAL_CACHE_DIR" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1]) / 'p/libxev-0.0.0-86vtc4IcEwCqEYxEYoN_3KXmc6A9VLcm22aVImfvecYs/src/backend/kqueue.zig'
s = p.read_text()
old = '.machport => if (comptime builtin.os.tag != .macos) return null else kevent'
new = '.machport => if (comptime !builtin.os.tag.isDarwin()) return null else kevent'
if old not in s and new not in s:
    raise SystemExit('libxev patch no longer matches; review the dependency.')
s = s.replace(old, new).replace('if (comptime builtin.target.os.tag == .macos) {', 'if (comptime builtin.target.os.tag.isDarwin()) {')
p.write_text(s)
PY
"$ZIG" build -Demit-macos-app=false -Dsentry=false -Doptimize=ReleaseFast -j4
mkdir -p "$ROOT/Frameworks"
ditto macos/GhosttyKit.xcframework "$ROOT/Frameworks/GhosttyKit.xcframework"
"$ROOT/scripts/verify-ghostty.sh" "$ROOT/Frameworks/GhosttyKit.xcframework"
python3 - "$ROOT" "$EXPECTED" "$ZIG" <<'PY'
import json, pathlib, subprocess, sys
root, revision, zig = sys.argv[1:]
metadata = {'ghostty': revision, 'zig': subprocess.check_output([zig, 'version'], text=True).strip(),
            'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
            'configuration': 'ReleaseFast; sentry=false; libxev iOS machport patch'}
pathlib.Path(root, 'Frameworks/build-info.json').write_text(json.dumps(metadata, indent=2) + '\n')
PY

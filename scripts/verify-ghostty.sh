#!/usr/bin/env bash
# Adapted from baxian-app-ios under Apache-2.0; see Licenses/baxian-app-ios-Apache-2.0.txt.
#
# Verify Frameworks/GhosttyKit.xcframework holds the three expected slices
# (macOS-universal + iOS-device + iOS-simulator, spec §3) as static archives
# whose Mach-O platform matches the Info.plist declaration, so a
# cache-restored artifact is proven intact before anything links against it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
XCFRAMEWORK="${1:-$REPO_DIR/Frameworks/GhosttyKit.xcframework}"
PLIST="$XCFRAMEWORK/Info.plist"

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ -d "$XCFRAMEWORK" ]] || fail "xcframework not found at $XCFRAMEWORK"
[[ -f "$PLIST" ]] || fail "Info.plist missing in $XCFRAMEWORK"

LIBS_JSON="$(plutil -convert json -o - "$PLIST")"

COUNT="$(jq '.AvailableLibraries | length' <<<"$LIBS_JSON")"
[[ "$COUNT" -eq 3 ]] || fail "expected 3 slices, Info.plist lists $COUNT"

plist_field() {
  jq -r --arg p "$1" --arg v "$2" --arg f "$3" \
    '.AvailableLibraries[]
     | select(.SupportedPlatform == $p and ((.SupportedPlatformVariant // "") == $v))
     | .[$f]' <<<"$LIBS_JSON"
}

# LC_BUILD_VERSION platform ids: 1 = macOS, 2 = iOS, 7 = iOS simulator.
check_slice() {
  local platform="$1" variant="$2" label="$3" required_archs="$4" macho_platform="$5"
  local id path lib archs arch platforms

  id="$(plist_field "$platform" "$variant" LibraryIdentifier)"
  [[ -n "$id" ]] || fail "$label slice missing from Info.plist"

  path="$(plist_field "$platform" "$variant" LibraryPath)"
  lib="$XCFRAMEWORK/$id/$path"
  [[ -s "$lib" ]] || fail "$label binary missing or empty at $lib"

  file -b "$lib" | grep -q "ar archive" \
    || fail "$label binary is not a static archive: $(file -b "$lib" | head -1)"

  archs="$(lipo -archs "$lib" 2>/dev/null)" || fail "$label binary unreadable by lipo at $lib"
  for arch in $required_archs; do
    grep -qw "$arch" <<<"$archs" || fail "$label binary lacks $arch (has: $archs)"
    # Every archive member must match, or a stray cross-platform object could
    # slip into the cache and only surface later at app link time.
    platforms="$(otool -arch "$arch" -l "$lib" | awk '$1 == "platform" {print $2}' | sort -u | xargs)"
    [[ "$platforms" == "$macho_platform" ]] \
      || fail "$label $arch members built for Mach-O platform(s) ${platforms:-none}, expected $macho_platform"
  done

  echo "    ok: $label ($id, $archs, $(du -h "$lib" | cut -f1 | tr -d ' '))"
}

echo "==> Verifying $XCFRAMEWORK"
check_slice ios "" "iOS device" arm64 2
check_slice ios simulator "iOS simulator" arm64 7
check_slice macos "" "macOS" "arm64 x86_64" 1
echo "==> All three slices intact"

#!/bin/bash
# Compile and cert-sign a test-only app in a fresh /tmp directory. Never launch it.
# Usage: build-fixture.sh [/tmp/new-directory]; fails if output exists.
set -euo pipefail
source_dir="$(cd "$(dirname "$0")" && pwd -P)"
output="${1:-$(mktemp -d /tmp/leyline-native-acceptance-build.XXXXXX)/artifact}"
case "$output" in /tmp/*) ;; *) echo 'output must be under /tmp' >&2; exit 64;; esac
[[ ! -e "$output" ]] || { echo 'output already exists' >&2; exit 65; }
app="$output/Leyline Acceptance Fixture.app"
mkdir -p "$app/Contents/MacOS"
cp "$source_dir/AcceptanceFixture.Info.plist" "$app/Contents/Info.plist"
fixture_architecture="$(/usr/bin/uname -m)"
case "$fixture_architecture" in arm64|x86_64) ;; *) echo 'unsupported native architecture' >&2; exit 65;; esac
# Explicitly bind Mach-O minimum OS. Ambient MACOSX_DEPLOYMENT_TARGET must not
# make a14.0 Info.plist bundle unlaunchable on the actual host.
xcrun swiftc -target "$fixture_architecture-apple-macos14.0" -swift-version 5 -O -framework AppKit -framework ScreenCaptureKit \
  -framework CoreMedia -framework CoreVideo -framework CoreImage -framework CryptoKit \
  "$source_dir/AcceptanceFixture.swift" -o "$app/Contents/MacOS/AcceptanceFixture"
# Fail honestly if the stable signing identity is unavailable; no ad-hoc fallback.
/usr/bin/codesign --force --sign "${LEYLINE_CODESIGN_IDENTITY:--}" \
  --identifier org.leyline.native-acceptance --timestamp=none "$app"
/usr/bin/codesign --verify --strict "$app"
printf '%s\n' "$app"

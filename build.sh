#!/bin/bash
# Builds DimBar.app. arm64 only — DDC over IOAVService needs Apple Silicon.
#
#   ./build.sh           build build/DimBar.app
#   ./build.sh --dist    also produce build/DimBar-<version>.zip
set -euo pipefail
cd "$(dirname "$0")"

APP="build/DimBar.app"
BIN="$APP/Contents/MacOS/DimBar"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ ! -f resources/AppIcon.icns ]; then
  echo "==> rendering app icon"
  swift tools/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o resources/AppIcon.icns
fi

echo "==> compiling"
swiftc -O \
  -target arm64-apple-macos13.0 \
  -o "$BIN" \
  Sources/DDC.swift Sources/App.swift Sources/main.swift

cp Info.plist "$APP/Contents/Info.plist"
cp resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null || echo "   (codesign skipped)"

echo "==> built: $APP (v$VERSION)"

if [ "${1:-}" = "--dist" ]; then
  ditto -c -k --keepParent "$APP" "build/DimBar-$VERSION.zip"
  echo "==> packaged: build/DimBar-$VERSION.zip"
fi

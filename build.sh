#!/bin/zsh
# Builds "build/Hotspot Saver.app" with the Xcode Command Line Tools (no Xcode project needed).
set -euo pipefail
cd "${0:A:h}"

APP="build/Hotspot Saver.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -swift-version 5 -O \
  -target "$(uname -m)-apple-macos14.0" \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/HotspotSaver"

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

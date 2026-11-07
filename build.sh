#!/bin/zsh
# Builds "build/Hotspot Saver.app" with the Xcode Command Line Tools (no Xcode project needed).
# The app runs on both Apple-silicon and Intel Macs (macOS 14 or later).
set -euo pipefail
cd "${0:A:h}"

APP="build/Hotspot Saver.app"
BIN="$APP/Contents/MacOS/HotspotSaver"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/arch

for arch in arm64 x86_64; do
  swiftc -swift-version 5 -O \
    -target "$arch-apple-macos14.0" \
    Sources/*.swift \
    -module-cache-path build/arch/cache \
    -o "build/arch/HotspotSaver-$arch"
done
lipo -create build/arch/HotspotSaver-arm64 build/arch/HotspotSaver-x86_64 -output "$BIN"
rm -rf build/arch

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP ($(lipo -archs "$BIN"))"

#!/bin/zsh
# Packages the app as build/HotspotSaver.zip for the GitHub Releases page.
#   ./release.sh            build and package only
#   ./release.sh --publish  also push, then create release v<version> with the zip attached
# To share it, send https://github.com/kennabt-jpg/HotspotSaver#download (it has the install steps).
# The zip always has the same name, so its download button always gets the newest version:
#   https://github.com/kennabt-jpg/HotspotSaver/releases/latest/download/HotspotSaver.zip
set -euo pipefail
cd "${0:A:h}"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
./build.sh
ZIP="build/HotspotSaver.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "build/Hotspot Saver.app" "$ZIP"
echo "Packaged $ZIP ($(du -h "$ZIP" | cut -f1 | tr -d ' ')) for version $VERSION"

[[ "${1:-}" == "--publish" ]] || exit 0

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Commit your changes first."; exit 1
fi
if gh release view "v$VERSION" >/dev/null 2>&1; then
  echo "Release v$VERSION already exists. Raise CFBundleShortVersionString in Info.plist first."; exit 1
fi
git push
gh release create "v$VERSION" "$ZIP" --title "Hotspot Saver $VERSION" --notes "$(cat <<'NOTES'
**Pauses cloud sync and app auto-updaters while your Mac is tethered to a phone hotspot, and turns them back on when you're back on a regular network.**

### Install (macOS 14 or later; do this on your Mac, not a phone)
1. Under **Assets** below, click **HotspotSaver.zip** (not *Source code*). Safari unzips it for you; in Chrome or Firefox, double-click **HotspotSaver.zip** in your **Downloads** folder.
2. In Finder, drag **Hotspot Saver** by itself from **Downloads** onto **Applications** in the sidebar, then open it from **Applications**. If it says *Move Hotspot Saver to your Applications folder*, click **Quit** and do this step again.
3. The first time, macOS blocks it, because it isn't signed through Apple's paid developer program. Close the warning with **Done** (or **Cancel**), not *Move to Trash*. Then open the Apple menu → **System Settings → Privacy & Security**, scroll down to **Security**, and click **Open Anyway** next to Hotspot Saver. When the warning appears again, click **Open Anyway** (or **Open**), then enter your Mac password or use Touch ID. The button only stays there for about an hour; if it's gone, double-click Hotspot Saver again and come back. (On macOS 14 Sonoma you can instead Control-click Hotspot Saver in Applications, choose **Open**, then click **Open**.)
4. Choose **Open at Login** when asked. macOS may show a *Background Items Added* notification; that's expected. There's no window or Dock icon: look for its icon (two linked rings) near the right end of the menu bar at the top of the screen, and click it to use the app. If you can't see it, the menu bar may be full; on a MacBook with a notch, icons can hide behind the notch.

**To remove it:** click its menu-bar icon, untick **Open at login**, choose **Quit Hotspot Saver** (it turns everything back on first), then drag **Hotspot Saver** from Applications to the Trash. If you already deleted the app, switch off HotspotSaver in **System Settings → General → Login Items** (called **Login Items & Extensions** on macOS 15 and later).

Full instructions: https://github.com/kennabt-jpg/HotspotSaver#download
NOTES
)"
echo "Published: https://github.com/kennabt-jpg/HotspotSaver/releases/tag/v$VERSION"

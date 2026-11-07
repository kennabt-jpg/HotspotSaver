#!/bin/zsh
# Turns everything back on, then removes Hotspot Saver. Your settings folder is kept unless you pass --all.
set -uo pipefail

UID_NUM=$(id -u)
LABEL="local.HotspotSaver"
APP="$HOME/Applications/Hotspot Saver.app"
BIN="$APP/Contents/MacOS/HotspotSaver"

# Ask the running app to turn everything back on and quit; then make sure nothing is left paused.
[ -x "$BIN" ] && "$BIN" quit 2>/dev/null
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null
pkill -x HotspotSaver 2>/dev/null
sleep 1
[ -x "$BIN" ] && "$BIN" resume all

rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/bin/hotspot-saver"
rm -rf "$APP"
if [ "${1:-}" = "--all" ]; then
  rm -rf "$HOME/Library/Application Support/HotspotSaver" "$HOME/Library/Logs/HotspotSaver.log" "$HOME/Library/Logs/HotspotSaver.log.1"
fi
echo "Hotspot Saver removed."

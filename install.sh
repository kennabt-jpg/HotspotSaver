#!/bin/zsh
# Builds Hotspot Saver, installs it to ~/Applications, starts it, and sets it to open at login.
set -euo pipefail
cd "${0:A:h}"

./build.sh

UID_NUM=$(id -u)
LABEL="local.HotspotSaver"
APP="$HOME/Applications/Hotspot Saver.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
CLI="$HOME/.local/bin/hotspot-saver"

# Stop a running copy (anything it paused is turned back on when the new copy starts).
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
pkill -x HotspotSaver 2>/dev/null || true
sleep 1

mkdir -p "$HOME/Applications" "$HOME/.local/bin" "$HOME/Library/LaunchAgents"
rm -rf "$APP"
cp -R "build/Hotspot Saver.app" "$APP"

cat > "$CLI" <<EOF
#!/bin/sh
exec "$APP/Contents/MacOS/HotspotSaver" "\$@"
EOF
chmod +x "$CLI"

cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP/Contents/MacOS/HotspotSaver</string>
        <string>--menubar</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$UID_NUM" "$AGENT"
echo "Installed: $APP"
echo "Command line: $CLI   (try: hotspot-saver status)"

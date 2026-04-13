#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SOURCE="$ROOT_DIR/build/IPMonitor.app"
APP_DEST="$HOME/Applications/IPMonitor.app"
AGENT_DIR="$HOME/Library/LaunchAgents"
AGENT_PLIST="$AGENT_DIR/local.ipmonitor.plist"
LABEL="local.ipmonitor"

if [[ ! -d "$APP_SOURCE" ]]; then
  echo "Build the app first by running ./build.sh" >&2
  exit 1
fi

mkdir -p "$HOME/Applications" "$AGENT_DIR"
rm -rf "$APP_DEST"
cp -R "$APP_SOURCE" "$APP_DEST"

cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP_DEST/Contents/MacOS/IPMonitor</string>
  </array>
  <key>KeepAlive</key>
  <true/>
  <key>RunAtLoad</key>
  <true/>
  <key>ProcessType</key>
  <string>Background</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
launchctl enable "gui/$(id -u)/$LABEL"

echo "Installed IPMonitor to $APP_DEST"
echo "LaunchAgent loaded as $LABEL"

#!/bin/zsh
set -euo pipefail

APP_DEST="$HOME/Applications/IPMonitor.app"
AGENT_PLIST="$HOME/Library/LaunchAgents/local.ipmonitor.plist"
LABEL="local.ipmonitor"

launchctl bootout "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null || true
rm -f "$AGENT_PLIST"
rm -rf "$APP_DEST"

echo "Removed LaunchAgent $LABEL"
echo "Removed installed app at $APP_DEST"

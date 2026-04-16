#!/bin/zsh

set -euo pipefail

APP_NAME="${APP_NAME:-DownloadsOrganizer}"
LAUNCH_AGENT_LABEL="${LAUNCH_AGENT_LABEL:-io.github.downloadsorganizer}"
PLIST_PATH="$HOME/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
rm -f "$PLIST_PATH"
pkill -f "$HOME/Applications/${APP_NAME}.app/Contents/MacOS/${APP_NAME}" 2>/dev/null || true

echo "removed launch agent: $PLIST_PATH"

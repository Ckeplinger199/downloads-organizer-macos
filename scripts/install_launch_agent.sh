#!/bin/zsh

set -euo pipefail

APP_NAME="${APP_NAME:-DownloadsOrganizer}"
APP_PATH="${APP_PATH:-$HOME/Applications/${APP_NAME}.app}"
LAUNCH_AGENT_LABEL="${LAUNCH_AGENT_LABEL:-io.github.downloadsorganizer}"
PLIST_PATH="$HOME/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"
LOG_DIR="$HOME/Library/Logs/${APP_NAME}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "missing app bundle: $APP_PATH" >&2
  echo "run ./scripts/build_app.sh first" >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>${LAUNCH_AGENT_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
      <string>/usr/bin/open</string>
      <string>-gj</string>
      <string>${APP_PATH}</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>StandardOutPath</key>
    <string>${LOG_DIR}/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/launchd.err.log</string>
  </dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
launchctl kickstart -k "gui/$(id -u)/${LAUNCH_AGENT_LABEL}" 2>/dev/null || true

echo "installed launch agent: $PLIST_PATH"

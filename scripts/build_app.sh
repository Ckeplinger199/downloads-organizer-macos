#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${APP_NAME:-DownloadsOrganizer}"
BUNDLE_ID="${BUNDLE_ID:-io.github.downloadsorganizer}"
APP_PATH="${APP_PATH:-$HOME/Applications/${APP_NAME}.app}"
SOURCE_PATH="$ROOT_DIR/app/DownloadsOrganizer.swift"
BIN_PATH="$APP_PATH/Contents/MacOS/$APP_NAME"
PLIST_PATH="$APP_PATH/Contents/Info.plist"

if [[ ! -f "$SOURCE_PATH" ]]; then
  echo "missing source: $SOURCE_PATH" >&2
  exit 1
fi

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"

swiftc "$SOURCE_PATH" -o "$BIN_PATH"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
  </dict>
</plist>
EOF

codesign --force --deep --sign - "$APP_PATH"

echo "built $APP_PATH"

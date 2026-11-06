#!/bin/zsh
# Build Mac Pulse, wrap it into an .app bundle, sign ad-hoc, install to ~/Applications and launch.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP="build/Mac Pulse.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MacPulse "$APP/Contents/MacOS/MacPulse"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Mac Pulse</string>
  <key>CFBundleDisplayName</key><string>Mac Pulse</string>
  <key>CFBundleIdentifier</key><string>com.mkliakhin.macpulse</string>
  <key>CFBundleExecutable</key><string>MacPulse</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"

DEST="$HOME/Applications/Mac Pulse.app"
mkdir -p "$HOME/Applications"
pkill -x MacPulse 2>/dev/null || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"
open "$DEST"
echo "Installed: $DEST"

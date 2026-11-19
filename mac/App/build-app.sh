#!/bin/bash
# T13: builds Hamsa.app without XcodeGen/Xcode project: SwiftPM binary + hand-written bundle, ad-hoc signed.
# Keep the Info.plist keys in step with project.yml (LSUIElement + the two usage strings).
# Usage: mac/App/build-app.sh [debug|release]   -> mac/.build/Hamsa.app
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-debug}"
swift build -j 2 -c "$CONFIG" --product HamsaApp
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP=.build/Hamsa.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/HamsaApp" "$APP/Contents/MacOS/Hamsa"
# SwiftPM resource bundles of dependencies (swift-transformers Hub, swift-crypto).
# shortcut: SwiftPM's Bundle.module looks beside the .app and then at the absolute .build path, so this app only
# runs on the machine that built it; copy them to Resources for the day a real Xcode build replaces this script.
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.hamsa.Hamsa</string>
  <key>CFBundleName</key><string>Hamsa</string>
  <key>CFBundleExecutable</key><string>Hamsa</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.4</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Hamsa transcribes your side of the call.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Hamsa transcribes the other side of the call.</string>
</dict>
</plist>
PLIST
codesign -s - --force --deep "$APP"
echo "built $PWD/$APP"

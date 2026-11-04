#!/bin/bash
# Build "DS4 Launcher.app" from DS4Launcher.swift using the Command Line Tools.
# Usage: ./build.sh            -> build/DS4 Launcher.app
#        ./build.sh --install  -> also copy to ~/Applications
set -euo pipefail
cd "$(dirname "$0")"

APP="build/DS4 Launcher.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library -swift-version 5 \
  -target arm64-apple-macos14.0 \
  -o "$APP/Contents/MacOS/DS4Launcher" DS4Launcher.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DS4 Launcher</string>
  <key>CFBundleDisplayName</key><string>DS4 Launcher</string>
  <key>CFBundleIdentifier</key><string>local.ds4.launcher</string>
  <key>CFBundleExecutable</key><string>DS4Launcher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/DS4 Launcher.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "Installed to ~/Applications/DS4 Launcher.app"
fi

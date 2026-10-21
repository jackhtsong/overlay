#!/bin/bash
# Builds Overlay.app next to this script. UNIVERSAL=1 builds for both Apple Silicon and Intel.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=1.0.0
MIN_MACOS=13.0
APP=Overlay.app
BIN="$APP/Contents/MacOS/Overlay"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
if [ "${UNIVERSAL:-}" = 1 ]; then
  for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "$arch-apple-macos$MIN_MACOS" main.swift -o "$BIN-$arch"
  done
  lipo -create "$BIN-arm64" "$BIN-x86_64" -output "$BIN"
  rm "$BIN-arm64" "$BIN-x86_64"
else
  swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos$MIN_MACOS" main.swift -o "$BIN"
fi

# Spotify's official logo (white, full logo), shown as the attribution Spotify requires.
mkdir -p "$APP/Contents/Resources"
[ -f assets/spotify-logo.png ] && cp assets/spotify-logo.png "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Overlay</string>
  <key>CFBundleIdentifier</key><string>local.overlay</string>
  <key>CFBundleName</key><string>Overlay</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Controls Spotify playback.</string>
</dict></plist>
EOF

codesign --force --sign - "$APP"
echo "Built $APP $VERSION"

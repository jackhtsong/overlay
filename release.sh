#!/bin/bash
# Builds a universal Overlay.app and zips it for a GitHub release.
set -euo pipefail
cd "$(dirname "$0")"

UNIVERSAL=1 ./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Overlay.app/Contents/Info.plist)
ZIP="Overlay-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent Overlay.app "$ZIP"

lipo -archs Overlay.app/Contents/MacOS/Overlay
shasum -a 256 "$ZIP"
echo "Upload $ZIP to a new GitHub release tagged v$VERSION"

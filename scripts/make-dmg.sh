#!/bin/zsh
# Build a Release copy of LocationLab and package it as a drag-to-Applications DMG.
# For local installs only: signed with your Apple Development certificate, not notarized.
#
# Usage:  ./scripts/make-dmg.sh
# Output: dist/LocationLab <version>.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="LocationLab"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
STAGE="$BUILD/dmg-staging"

cd "$ROOT"
echo "→ Building Release…"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
  -derivedDataPath "$BUILD/DerivedData" build -quiet

APP="$BUILD/DerivedData/Build/Products/Release/$APP_NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

echo "→ Checking signature…"
codesign --verify --deep --strict "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "^Authority=" | head -1 || true

echo "→ Packaging DMG…"
rm -rf "$STAGE"; mkdir -p "$STAGE" "$DIST"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/$APP_NAME $VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet
rm -rf "$STAGE"

echo "✓ $DMG"

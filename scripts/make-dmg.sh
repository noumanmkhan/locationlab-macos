#!/bin/zsh
# Build LocationLab and package it as a drag-to-Applications DMG.
#
# Usage:
#   ./scripts/make-dmg.sh            Local build: Apple Development signing, not notarized.
#                                    Runs on your own Macs; other Macs get the "unsafe app" warning.
#   ./scripts/make-dmg.sh --release  Public build: Developer ID signing + Apple notarization +
#                                    stapled ticket. Opens on any Mac without warnings.
#
# One-time setup for --release:
#   1. Xcode › Settings › Accounts › your team › Manage Certificates… › + › Developer ID Application
#   2. Create an app-specific password at account.apple.com, then:
#        xcrun notarytool store-credentials "LocationLab" --apple-id "<Apple ID>" --team-id 76LNBDGT55
#
# Output: dist/LocationLab <version>.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="LocationLab"
TEAM_ID="76LNBDGT55"
NOTARY_PROFILE="${NOTARY_PROFILE:-LocationLab}"   # keychain profile from `notarytool store-credentials`
BUILD="$ROOT/build"
DIST="$ROOT/dist"
STAGE="$BUILD/dmg-staging"

RELEASE=0
case "${1:-}" in
  --release) RELEASE=1 ;;
  "") ;;
  *) echo "Unknown option: $1 (use --release or nothing)"; exit 2 ;;
esac

fail() { echo "✗ $*" >&2; exit 1; }

cd "$ROOT"

# Universal (Apple silicon + Intel) build, so the DMG works on any supported Mac.
BUILD_ARGS=(-project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release
            -destination "generic/platform=macOS" -derivedDataPath "$BUILD/DerivedData")

if (( RELEASE )); then
  echo "→ Checking release prerequisites…"
  SIGN_ID="$(security find-identity -v -p codesigning | grep "Developer ID Application" | grep "($TEAM_ID)" | head -1 \
             | sed -E 's/.*"(.*)"/\1/')" || true
  [[ -n "$SIGN_ID" ]] || fail "No 'Developer ID Application' certificate for team $TEAM_ID in your keychain.
  Create one: Xcode › Settings › Accounts › Manage Certificates… › + › Developer ID Application"
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || fail "No notarization login stored as \"$NOTARY_PROFILE\".
  Run: xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id \"<Apple ID>\" --team-id $TEAM_ID"
  echo "  Signing as: $SIGN_ID"
  # Developer ID needs a secure timestamp and the hardened runtime (already on in the project).
  BUILD_ARGS+=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$SIGN_ID" DEVELOPMENT_TEAM="$TEAM_ID"
               PROVISIONING_PROFILE_SPECIFIER= "OTHER_CODE_SIGN_FLAGS=--timestamp"
               CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
fi

echo "→ Building Release (universal)…"
rm -rf "$BUILD/DerivedData/Build/Products/Release/$APP_NAME.app"
xcodebuild "${BUILD_ARGS[@]}" build -quiet

APP="$BUILD/DerivedData/Build/Products/Release/$APP_NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

echo "→ Checking signature…"
codesign --verify --deep --strict "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "^Authority=" | head -1 || true
lipo -archs "$APP/Contents/MacOS/$APP_NAME" | sed 's/^/  Architectures: /'

echo "→ Packaging DMG…"
rm -rf "$STAGE"; mkdir -p "$STAGE" "$DIST"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/$APP_NAME $VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet
rm -rf "$STAGE"

if (( RELEASE )); then
  echo "→ Signing DMG…"
  codesign --sign "$SIGN_ID" --timestamp "$DMG"

  echo "→ Notarizing (uploading to Apple and waiting; usually a few minutes)…"
  RESULT="$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"
  STATUS="$(plutil -extract status raw - <<< "$RESULT" 2>/dev/null || echo unknown)"
  SUB_ID="$(plutil -extract id raw - <<< "$RESULT" 2>/dev/null || echo "")"
  if [[ "$STATUS" != "Accepted" ]]; then
    echo "$RESULT"
    [[ -n "$SUB_ID" ]] && xcrun notarytool log "$SUB_ID" --keychain-profile "$NOTARY_PROFILE" || true
    fail "Notarization status: $STATUS"
  fi
  echo "  Accepted (submission $SUB_ID)"

  echo "→ Stapling the notarization ticket…"
  xcrun stapler staple -q "$DMG"
  xcrun stapler validate -q "$DMG"

  echo "→ Checking Gatekeeper accepts it…"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi

echo "✓ $DMG"

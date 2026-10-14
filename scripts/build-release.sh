#!/bin/bash
# Release: xcodegen → archive → export (Developer ID) → notarize → staple → DMG.
#
# Requires a "Developer ID Application" certificate in the keychain and a notarytool profile:
#   xcrun notarytool store-credentials "$NOTARY_PROFILE" --apple-id "$APPLE_ID" --team-id "$TEAM_ID"
#
# Env: TEAM_ID (default 89K4SJGXLP), APPLE_ID (only used in the hint above), NOTARY_PROFILE (required)
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID="${TEAM_ID:-89K4SJGXLP}"
NOTARY_PROFILE="${NOTARY_PROFILE:-EasyMAC-notary}"   # created with the team API key 9NRXWCW938

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "error: no 'Developer ID Application' certificate in the keychain." >&2
  echo "Create one at developer.apple.com → Certificates (team $TEAM_ID) and install it." >&2
  exit 1
fi

VERSION=$(grep -E 'MARKETING_VERSION' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
BUILD_DIR=build/release
ARCHIVE="$BUILD_DIR/EasyMAC.xcarchive"
EXPORT="$BUILD_DIR/export"
DIST=dist
DMG="$DIST/EasyMAC-$VERSION.dmg"

rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR" "$DIST"
xcodegen generate --quiet

echo "▸ Archiving $VERSION"
xcodebuild -project EasyMAC.xcodeproj -scheme EasyMAC -configuration Release \
  -archivePath "$ARCHIVE" DEVELOPMENT_TEAM="$TEAM_ID" archive -quiet

cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
PLIST

echo "▸ Exporting"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" -quiet
APP="$EXPORT/EasyMAC.app"

echo "▸ Notarizing app"
ditto -c -k --keepParent "$APP" "$BUILD_DIR/EasyMAC.zip"
xcrun notarytool submit "$BUILD_DIR/EasyMAC.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

echo "▸ Building DMG"
STAGE="$BUILD_DIR/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/EasyMAC.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "EasyMAC $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --sign "Developer ID Application" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "✓ $DMG"

#!/bin/bash
# Optimised build signed with your "Apple Development" certificate, installed to /Applications and launched.
# Signing with the same certificate every time keeps the Accessibility / Screen Recording grants across updates.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project EasyMAC.xcodeproj -scheme EasyMAC -configuration Release \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=89K4SJGXLP \
  build -quiet
APP=build/DerivedData/Build/Products/Release/EasyMAC.app
codesign --verify --deep --strict "$APP"
osascript -e 'tell application id "com.appalbania.easymac" to quit' >/dev/null 2>&1 || true
pkill -x EasyMAC 2>/dev/null || true
sleep 0.5
rm -rf /Applications/EasyMAC.app
ditto "$APP" /Applications/EasyMAC.app
open /Applications/EasyMAC.app
echo "Installed /Applications/EasyMAC.app ($(defaults read /Applications/EasyMAC.app/Contents/Info.plist CFBundleShortVersionString))"

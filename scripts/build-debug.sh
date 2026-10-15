#!/bin/bash
# Debug build.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project EasyMAC.xcodeproj -scheme EasyMAC -configuration Debug \
  -derivedDataPath build/DerivedData build | xcbeautify 2>/dev/null || \
xcodebuild -project EasyMAC.xcodeproj -scheme EasyMAC -configuration Debug \
  -derivedDataPath build/DerivedData build
echo "Built: build/DerivedData/Build/Products/Debug/EasyMAC.app"

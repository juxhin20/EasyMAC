#!/bin/bash
# Debug build + tests.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project EasyMAC.xcodeproj -scheme EasyMAC -configuration Debug \
  -derivedDataPath build/DerivedData build test | xcbeautify 2>/dev/null || \
xcodebuild -project EasyMAC.xcodeproj -scheme EasyMAC -configuration Debug \
  -derivedDataPath build/DerivedData build test
echo "Built: build/DerivedData/Build/Products/Debug/EasyMAC.app"

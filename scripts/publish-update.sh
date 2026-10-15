#!/bin/bash
# Publishes the notarized DMG from build-release.sh as a Sparkle update.
#   1. bump MARKETING_VERSION + CURRENT_PROJECT_VERSION in project.yml
#   2. ./scripts/build-release.sh
#   3. ./scripts/publish-update.sh        (optional: release notes in dist/EasyMAC-<version>.html)
# Signs with the Sparkle EdDSA key from the login keychain, rebuilds appcast.xml and uploads
# DMG + appcast to https://appalbania.com/easymac/ (SSH alias `appalbania`).
set -euo pipefail
cd "$(dirname "$0")/.."

SPARKLE_VERSION=2.10.0
TOOLS=build/sparkle/bin
REMOTE_HOST=appalbania
REMOTE_DIR=appalbania.com/app/public/easymac
URL_PREFIX=https://appalbania.com/easymac/

if [ ! -x "$TOOLS/generate_appcast" ]; then
  mkdir -p build/sparkle
  curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" | tar -xJ -C build/sparkle
fi

ls dist/EasyMAC-*.dmg >/dev/null 2>&1 || { echo "error: no DMG in dist/ — run build-release.sh first" >&2; exit 1; }

# Keep previously published DMGs so generate_appcast can build delta updates and history.
mkdir -p dist
rsync -a --ignore-existing --exclude='EasyMAC.dmg' --exclude='download/' "$REMOTE_HOST:$REMOTE_DIR/" dist/ 2>/dev/null || true

"$TOOLS/generate_appcast" --download-url-prefix "$URL_PREFIX" --link https://appalbania.com -o dist/appcast.xml dist/

ssh "$REMOTE_HOST" "mkdir -p $REMOTE_DIR"
rsync -av --include='*.dmg' --include='*.delta' --include='*.html' --include='appcast.xml' --exclude='*' dist/ "$REMOTE_HOST:$REMOTE_DIR/"
# Stable "latest" link (README / GitHub button): /easymac/download/ redirects to the newest DMG.
# A redirect, not a copied file: Cloudflare caches .dmg files for a year, versioned names never go stale.
VERSION=$(grep -E '^\s*MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"(.*)".*/\1/')
ssh "$REMOTE_HOST" "mkdir -p $REMOTE_DIR/download && rm -f $REMOTE_DIR/EasyMAC.dmg && printf '%s\n' '<?php' 'header(\"Cache-Control: no-store\");' 'header(\"Location: ${URL_PREFIX}EasyMAC-$VERSION.dmg\", true, 302);' > $REMOTE_DIR/download/index.php"
echo "✓ Published. Feed: ${URL_PREFIX}appcast.xml"

#!/bin/bash
# Uploads the landing page (site/) to https://appalbania.com/easymac/ — DMGs/appcast are handled by publish-update.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(grep -E 'MARKETING_VERSION' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
STAGE=build/site && rm -rf "$STAGE" && cp -R site "$STAGE"
# Point download buttons at the current version.
sed -i '' -E "s/EasyMAC-[0-9]+\.[0-9]+\.[0-9]+\.dmg/EasyMAC-$VERSION.dmg/g; s/(Version |EasyMAC )[0-9]+\.[0-9]+\.[0-9]+/\1$VERSION/g" "$STAGE/index.html"
ssh appalbania "mkdir -p appalbania.com/app/public/easymac/img"
rsync -av --delete "$STAGE/img/" appalbania:appalbania.com/app/public/easymac/img/
rsync -av "$STAGE/index.html" appalbania:appalbania.com/app/public/easymac/
ssh appalbania 'chown -R fly:fly appalbania.com/app/public/easymac'
echo "✓ https://appalbania.com/easymac/"

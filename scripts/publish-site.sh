#!/bin/bash
# Uploads the landing page (site/) to https://appalbania.com/easymac/ — DMGs/appcast are handled by publish-update.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(grep -E 'MARKETING_VERSION' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
STAGE=build/site && rm -rf "$STAGE" && cp -R site "$STAGE"
# Point download buttons at the current version.
sed -i '' -E "s/EasyMAC-[0-9]+\.[0-9]+\.[0-9]+\.dmg/EasyMAC-$VERSION.dmg/g; s/(Version |EasyMAC )[0-9]+\.[0-9]+\.[0-9]+/\1$VERSION/g" "$STAGE/index.html"
# Build the "What's new" list from releases/EasyMAC-<version>.html (newest first).
python3 - "$STAGE/index.html" "$VERSION" <<'PY'
import sys, glob, re, os
page, current = sys.argv[1], sys.argv[2]
dates = dict(l.split() for l in open("releases/dates.txt") if l.strip())
def key(p): return [int(x) for x in re.search(r"EasyMAC-([\d.]+)\.html", p).group(1).split(".")]
blocks = []
for path in sorted(glob.glob("releases/EasyMAC-*.html"), key=key, reverse=True):
    v = re.search(r"EasyMAC-([\d.]+)\.html", path).group(1)
    if v not in dates:  # draft notes: not released yet, never shown on the site
        continue
    body = open(path).read()
    tag = '<span class="tag">Latest</span>' if v == current else ""
    blocks.append(f'''      <article class="reveal">
        <header><h3>EasyMAC {v}</h3>{tag}<time>{dates.get(v, "")}</time>
          <span class="dl"><a href="EasyMAC-{v}.dmg">Download {v}</a></span></header>
        {body}
      </article>''')
html = open(page).read().replace("<!--RELEASES-->", "\n".join(blocks))
open(page, "w").write(html)
PY
ssh appalbania "mkdir -p appalbania.com/app/public/easymac/img"
rsync -av --delete "$STAGE/img/" appalbania:appalbania.com/app/public/easymac/img/
rsync -av "$STAGE/index.html" appalbania:appalbania.com/app/public/easymac/
ssh appalbania 'chown -R fly:fly appalbania.com/app/public/easymac'
echo "✓ https://appalbania.com/easymac/"

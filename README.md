# EasyMAC by AppAlbania

Native macOS multitasking: a compact strip of live window thumbnails, one-click project workspaces,
tiling presets and a Loop-style **snap wheel** (hold **fn** + move the mouse).

```bash
brew install xcodegen
./scripts/install-local.sh     # build, install to /Applications, launch
./scripts/build-debug.sh       # debug build + unit tests
NOTARY_PROFILE=… ./scripts/build-release.sh   # Developer ID + notarized DMG in dist/
```

| Action | Default |
|---|---|
| Show / hide sidebar | ⌥⇧S |
| Restore workspace 1–9 | ⌥1 … ⌥9 |
| Save current windows as workspace | ⌥⇧W |
| Window switcher | ⌥Tab (release ⌥ to focus) |
| Snap left / right / top / bottom | ⌃⌥ ← → ↑ ↓ (repeat left/right: ½ → ⅔ → ⅓) |
| Maximize / center / restore | ⌃⌥↩ / ⌃⌥C / ⌃⌥⌫ |
| Tile visible windows | ⌃⌥L |
| Snap wheel | hold fn, move mouse, release |

All shortcuts can be changed in Settings → Hotkeys. See `NOTES.md` for design decisions and limitations.

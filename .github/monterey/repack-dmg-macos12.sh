#!/usr/bin/env bash
# Extract the unsigned Desktop DMG, patch natives for macOS 12, rewrite the DMG.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
root=apps/desktop/.desktop-build/targets/mac-x64
dmg=$(find "$root" -name '*.dmg' -print | head -1)
test -n "$dmg" || { echo "no DMG under $root" >&2; exit 1; }
echo "source DMG: $dmg"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mnt="$work/mnt"
src="$work/src"
mkdir -p "$mnt" "$src"
hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$dmg"
# Copy volume contents (the .app plus any .DS_Store / Applications link)
rsync -a "$mnt"/ "$src"/
hdiutil detach "$mnt" || true
app=$(find "$src" -maxdepth 1 -name '*.app' | head -1)
test -n "$app" || { echo "no .app in DMG" >&2; exit 1; }
bash "$ROOT/.github/monterey/patch-app-natives-macos12.sh" "$app"
volname=$(basename "$app" .app)
out="$work/out.dmg"
# UDZO matches electron-builder's usual compressed read-only DMG.
hdiutil create -volname "$volname" -srcfolder "$src" -ov -format UDZO "$out"
# Replace in place (keep original name/path).
cp -f "$out" "$dmg"
echo "rewrote $dmg"
ls -l "$dmg"
shasum -a 256 "$dmg"

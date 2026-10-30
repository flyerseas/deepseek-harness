#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
root=apps/desktop/.desktop-build/targets/mac-x64
dmg=$(find "$root" -name '*.dmg' -print | head -1)
test -n "$dmg" || { echo "no DMG produced" >&2; exit 1; }
mnt=$(mktemp -d)
hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$dmg"
app=$(find "$mnt" -maxdepth 1 -name '*.app' | head -1)
echo "DMG: $dmg"; shasum -a 256 "$dmg"; ls -l "$dmg"
echo "LSMinimumSystemVersion: $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")"
for fw in "$app/Contents/Frameworks"/*.framework; do
  p="$fw/Resources/Info.plist"; [ -f "$p" ] && echo "$(basename "$fw"): $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$p" 2>/dev/null || echo n/a)"
done
LIMIT=12.0 VERBOSE=1 python3 .github/monterey/macho_minos.py "$app" | tee scan.txt
find "$app/Contents/Resources" -type f \( -name '*.tar.gz' -o -name '*.tgz' -o -name '*.tar.xz' \) -print0 | xargs -0 -r env LIMIT=12.0 python3 .github/monterey/macho_minos.py | tee -a scan.txt
echo "---- binaries above 12.0 or non-x86_64 ----"
grep '^BAD ' scan.txt | tee bad.txt || true
fail=0
while IFS= read -r l; do
  echo "WARN $l"
done < bad.txt || true
core=$(grep -E "^BAD $app/Contents/(MacOS|Frameworks)/" bad.txt || true)
critical=$(grep -E 'node-addon-require-builtin-darwin-x64|darwin-x64-napi-v9\.node' bad.txt || true)
sherpa=$(grep -E 'sherpa-onnx\.node' bad.txt || true)
hdiutil detach "$mnt" || true
if [ -n "$core" ]; then echo "FAIL core app/Electron binaries exceed macOS 12.0"; echo "$core"; fail=1; fi
if [ -n "$critical" ]; then echo "FAIL require-builtin still exceeds macOS 12.0"; echo "$critical"; fail=1; fi
if [ -n "$sherpa" ]; then echo "FAIL sherpa-onnx.node still exceeds macOS 12.0"; echo "$sherpa"; fail=1; fi
mkdir -p scan-out; cp scan.txt bad.txt scan-out/
exit "$fail"

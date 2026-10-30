#!/usr/bin/env bash
# Patch natives inside an already-built .app so macOS 12 can dlopen them.
# Usage: patch-app-natives-macos12.sh /path/to/DeepSeek\ Harness.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET_MINOS="${TARGET_MINOS:-12.0}"
APP="${1:?app path required}"
UNPACKED="$APP/Contents/Resources/app.asar.unpacked/dsh/node_modules"
REBUILT="$ROOT/.github/monterey/out/darwin-x64-napi-v9.node"

if [ ! -d "$UNPACKED" ]; then
  echo "missing unpacked dsh node_modules under $APP" >&2
  exit 1
fi

# Prefer the CI-rebuilt require-builtin binary when present.
# Paths may contain spaces (e.g. "DeepSeek Harness.app"); never word-split them.
while IFS= read -r dest; do
  [ -n "$dest" ] || continue
  if [ -f "$REBUILT" ]; then
    echo "install rebuilt require-builtin -> $dest"
    chmod u+w "$dest" 2>/dev/null || true
    tmp="${dest}.new"
    cp -f "$REBUILT" "$tmp"
    mv -f "$tmp" "$dest"
  fi
done < <(find "$UNPACKED" -type f -name 'darwin-x64-napi-v9.node' -print)

# Lower minos on require-builtin (safety) and sherpa-onnx — one path per python invoke.
list=$(mktemp)
find "$UNPACKED" -type f \( -name 'darwin-x64-napi-v9.node' -o -name 'sherpa-onnx.node' \) >"$list"
if [ -s "$list" ]; then
  echo "lowering minos on $(wc -l < "$list" | tr -d ' ') file(s) in app"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    python3 "$ROOT/.github/monterey/lower_macho_minos.py" "$TARGET_MINOS" "$f"
    VERBOSE=1 LIMIT="$TARGET_MINOS" python3 "$ROOT/.github/monterey/macho_minos.py" "$f"
  done <"$list"
fi
rm -f "$list"

# Fail if critical natives still exceed the target.
scan=$(mktemp)
LIMIT="$TARGET_MINOS" python3 "$ROOT/.github/monterey/macho_minos.py" "$UNPACKED" | tee "$scan"
if grep -E 'darwin-x64-napi-v9\.node|sherpa-onnx\.node' "$scan" | grep -q '^BAD '; then
  echo "FAIL: critical natives still exceed minos ${TARGET_MINOS}" >&2
  grep -E 'darwin-x64-napi-v9\.node|sherpa-onnx\.node' "$scan" | grep '^BAD ' >&2 || true
  rm -f "$scan"
  exit 1
fi
rm -f "$scan"
echo "app natives patched for macOS ${TARGET_MINOS}"

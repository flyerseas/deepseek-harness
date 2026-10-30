#!/usr/bin/env bash
# Lower minos on optional/experimental natives that ship prebuilt minos > 12.
# sherpa-onnx is experimental speech-to-text. require-builtin is also covered
# here as a safety net after the dedicated rebuild step.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET_MINOS="${TARGET_MINOS:-12.0}"
SCRIPT="$ROOT/.github/monterey/lower_macho_minos.py"

# Bash 3.2 on macOS runners has no mapfile; use a temp list instead.
list=$(mktemp)
find "$ROOT/node_modules" -type f \( \
  -name 'sherpa-onnx.node' -o \
  -name 'darwin-x64-napi-v9.node' \
\) >"$list" 2>/dev/null || true

if [ ! -s "$list" ]; then
  rm -f "$list"
  echo "no optional native targets found (ok on non-darwin hosts)"
  exit 0
fi

echo "Lowering minos to ${TARGET_MINOS} on $(wc -l < "$list" | tr -d ' ') file(s)"
# shellcheck disable=SC2046
python3 "$SCRIPT" "$TARGET_MINOS" $(cat "$list")

if command -v vtool >/dev/null 2>&1; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    sdk=$(vtool -show-build "$f" 2>/dev/null | awk '/sdk/{print $2; exit}') || sdk=15.0
    sdk=${sdk:-15.0}
    echo "vtool -set-build-version macos ${TARGET_MINOS} ${sdk} -replace $f"
    vtool -set-build-version macos "$TARGET_MINOS" "$sdk" -replace "$f" || {
      echo "vtool failed on $f; python rewrite already applied"
    }
  done <"$list"
fi

# shellcheck disable=SC2046
VERBOSE=1 LIMIT="$TARGET_MINOS" python3 "$ROOT/.github/monterey/macho_minos.py" $(cat "$list")
rm -f "$list"

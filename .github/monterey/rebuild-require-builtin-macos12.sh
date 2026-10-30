#!/usr/bin/env bash
# Rebuild node-addon-require-builtin darwin-x64 napi-v9 with macOS 12 deployment
# target, then replace every copy under the harness node_modules tree.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET_MINOS="${TARGET_MINOS:-12.0}"
NARB_REF="${NARB_REF:-a58d3599a2e551d7d706d1ff796c9fd4bbaff63c}"  # 0.1.9
WORKDIR="${RUNNER_TEMP:-/tmp}/narb-macos12-$$"
REPLACED=0

cleanup() { rm -rf "$WORKDIR" 2>/dev/null || true; }
trap cleanup EXIT

echo "==> Cloning dsh-node-addon-require-builtin @ ${NARB_REF}"
git clone https://github.com/deepseek-ai/dsh-node-addon-require-builtin.git "$WORKDIR"
git -C "$WORKDIR" checkout --detach "$NARB_REF"

echo "==> Installing addon workspace deps"
cd "$WORKDIR"
corepack enable
pnpm install --frozen-lockfile

echo "==> Building require-builtin napi prebuild (MACOSX_DEPLOYMENT_TARGET=${TARGET_MINOS})"
# Clang honors MACOSX_DEPLOYMENT_TARGET. Also wrap CXX so -mmacosx-version-min
# is on the argv even if some driver ignores the env var.
WRAP="$WORKDIR/cxx-macos12"
cat > "$WRAP" << WRAP
#!/usr/bin/env bash
exec /usr/bin/c++ -mmacosx-version-min=${TARGET_MINOS} "\$@"
WRAP
chmod +x "$WRAP"
export MACOSX_DEPLOYMENT_TARGET="$TARGET_MINOS"
export CXX="$WRAP"
export NARB_PRODUCT=require-builtin
export NARB_BACKEND=napi
export NARB_BUILD_OUTPUT=prebuild

pnpm build:ts
pnpm build:native

OUT="$WORKDIR/packages/require-builtin/darwin-x64/prebuilt/darwin-x64-napi-v9.node"
test -f "$OUT" || { echo "::error::rebuild did not produce $OUT"; exit 1; }

echo "==> Verifying rebuilt minos"
python3 "$ROOT/.github/monterey/macho_minos.py" "$OUT" | tee /tmp/narb-rebuild-scan.txt
if grep -q '^BAD ' /tmp/narb-rebuild-scan.txt; then
  echo "::warning::rebuild still stamped minos > ${TARGET_MINOS}; lowering load command"
  python3 "$ROOT/.github/monterey/lower_macho_minos.py" "$TARGET_MINOS" "$OUT"
  VERBOSE=1 LIMIT="$TARGET_MINOS" python3 "$ROOT/.github/monterey/macho_minos.py" "$OUT"
fi
if VERBOSE=1 LIMIT="$TARGET_MINOS" python3 "$ROOT/.github/monterey/macho_minos.py" "$OUT" | grep -q '^BAD '; then
  echo "::error::rebuilt require-builtin still exceeds minos ${TARGET_MINOS}"
  exit 1
fi

echo "==> Replacing prebuilts under $ROOT/node_modules"
while IFS= read -r -d '' dest; do
  echo "replace $dest"
  chmod u+w "$dest" 2>/dev/null || true
  # Copy to a temp then replace so we do not write through a pnpm store hardlink.
  tmp="${dest}.new"
  cp -f "$OUT" "$tmp"
  mv -f "$tmp" "$dest"
  REPLACED=$((REPLACED + 1))
done < <(find "$ROOT/node_modules" -type f -name 'darwin-x64-napi-v9.node' -print0)

if [ "$REPLACED" -eq 0 ]; then
  echo "::error::no node-addon-require-builtin-darwin-x64 prebuild found under node_modules"
  echo "pnpm optional deps present:"
  find "$ROOT/node_modules" -maxdepth 4 -iname '*require-builtin*' -print | head -50 || true
  exit 1
fi

echo "==> Replaced ${REPLACED} copy(ies). sha256=$(shasum -a 256 "$OUT" | awk '{print $1}') size=$(wc -c < "$OUT")"

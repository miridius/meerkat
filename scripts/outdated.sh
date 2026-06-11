#!/usr/bin/env bash
# Report stale pnpm + Hex dependencies. Always exits 0: it runs from
# the pre-push hook, and a stale dep is a separate upgrade commit,
# never a reason to block the push being made now. Skips when the
# registry is unreachable so hooks keep working offline.

set -uo pipefail

cd "$(dirname "$0")/.."

if ! curl -sf --max-time 3 https://registry.npmjs.org >/dev/null 2>&1; then
  echo "scripts/outdated.sh: registry unreachable — skipping outdated check."
  exit 0
fi

echo "=== pnpm outdated (root + assets) ==="
pnpm -r outdated || true

echo
echo "=== mix hex.outdated ==="
mix hex.outdated || true

exit 0

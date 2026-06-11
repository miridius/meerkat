#!/usr/bin/env bash
# Dependency gate: pre-push fails while any JS or Hex dependency is
# behind its latest release, except declared exemptions and releases
# younger than the 24h supply-chain floor (minimumReleaseAge in
# pnpm-workspace.yaml — too young to be installable, so not yet
# actionable). Emergency bypass: LEFTHOOK=0 git push.

set -uo pipefail

cd "$(dirname "$0")/.."

# package name → reason for lagging behind latest; applies to both
# ecosystems.
EXEMPT_JSON='{
  "shiki": "pinned to @git-diff-view/shiki'\''s shiki major; remove when upstream moves to shiki 4"
}'

# Unreachable registry fails the gate rather than skipping it — no
# work happens offline anyway, so a skip is just an unverified pass.
if ! curl -sf --max-time 5 https://registry.npmjs.org >/dev/null 2>&1; then
  echo "scripts/outdated.sh: registry unreachable — cannot verify dependencies are current."
  exit 1
fi

fail=0

echo "=== pnpm outdated (workspace) ==="
pnpm_json=$(pnpm -r outdated --format json 2>/dev/null || true)
if [[ -n "$pnpm_json" && "$pnpm_json" != "{}" ]]; then
  while IFS=$'\t' read -r name latest; do
    reason=$(jq -r --arg n "$name" '.[$n] // empty' <<<"$EXEMPT_JSON")
    if [[ -n "$reason" ]]; then
      echo "exempt: $name ($reason)"
      continue
    fi
    published=$(pnpm view "$name" time --json 2>/dev/null | jq -r --arg v "$latest" '.[$v] // empty')
    if [[ -n "$published" ]]; then
      age_s=$(python3 -c "
import datetime, sys
pub = datetime.datetime.fromisoformat(sys.argv[1].replace('Z', '+00:00'))
print(int((datetime.datetime.now(datetime.timezone.utc) - pub).total_seconds()))
" "$published" 2>/dev/null || echo 999999)
      if (( age_s < 86400 )); then
        echo "grace: $name@$latest is younger than the 24h release floor"
        continue
      fi
    fi
    echo "BLOCKED: $name is outdated (latest: $latest)"
    fail=1
  done < <(jq -r 'to_entries[] | [.key, .value.latest] | @tsv' <<<"$pnpm_json")
fi

echo
echo "=== mix hex.outdated ==="
hex_out=$(mix hex.outdated 2>/dev/null || true)
echo "$hex_out"
while read -r name; do
  reason=$(jq -r --arg n "$name" '.[$n] // empty' <<<"$EXEMPT_JSON")
  if [[ -n "$reason" ]]; then
    echo "exempt: $name ($reason)"
    continue
  fi
  echo "BLOCKED: $name is outdated"
  fail=1
done < <(awk '/Update (not )?possible/ {print $1}' <<<"$hex_out")

if [[ "$fail" != 0 ]]; then
  echo
  echo "scripts/outdated.sh: dependencies are behind latest. Upgrade them,"
  echo "or add an exemption with a reason in this script if the pin is"
  echo "deliberate."
  exit 1
fi

echo
echo "all dependencies current."
exit 0

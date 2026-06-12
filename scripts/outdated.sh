#!/usr/bin/env bash
# Dependency gate: pre-push fails while any JS or Hex dependency is
# behind its latest release, except declared exemptions and JS
# releases younger than the 24h supply-chain floor (minimumReleaseAge
# in pnpm-workspace.yaml — too young to be installable, so not yet
# actionable; Hex has no such floor). The gate fails CLOSED on its
# own breakage: missing tools, unreachable registries, or unparseable
# probe output block the push rather than skipping a check.
# Emergency bypass: LEFTHOOK=0 git push.

set -uo pipefail

cd "$(dirname "$0")/.."

# package name → reason for lagging behind latest; applies to both
# ecosystems.
EXEMPT_JSON='{
  "shiki": "pinned to @git-diff-view/shiki'\''s shiki major; remove when upstream moves to shiki 4"
}'

for tool in pnpm jq mix python3 curl; do
  command -v "$tool" >/dev/null || {
    echo "scripts/outdated.sh: required tool '$tool' missing — cannot verify dependencies."
    exit 1
  }
done

jq empty <<<"$EXEMPT_JSON" 2>/dev/null || {
  echo "scripts/outdated.sh: EXEMPT_JSON is invalid JSON — fix the exemption table."
  exit 1
}

for registry in https://registry.npmjs.org https://hex.pm; do
  curl -sf --max-time 5 "$registry" >/dev/null 2>&1 || {
    echo "scripts/outdated.sh: $registry unreachable — cannot verify dependencies are current."
    exit 1
  }
done

fail=0

echo "=== pnpm outdated (workspace) ==="
# pnpm outdated exits 1 when it FINDS outdated deps, so the exit code
# alone can't distinguish findings from breakage — valid JSON on
# stdout is the success signal.
pnpm_json=$(pnpm -r outdated --format json 2>&1)
pnpm_rc=$?
if ! jq empty <<<"$pnpm_json" 2>/dev/null; then
  echo "$pnpm_json"
  echo "scripts/outdated.sh: pnpm outdated produced no JSON (exit $pnpm_rc) — cannot verify JS deps."
  exit 1
fi
while IFS=$'\t' read -r name latest; do
  reason=$(jq -r --arg n "$name" '.[$n] // empty' <<<"$EXEMPT_JSON")
  if [[ -n "$reason" ]]; then
    echo "exempt: $name ($reason)"
    continue
  fi
  if ! published=$(pnpm view "$name" time --json 2>&1 | jq -r --arg v "$latest" '.[$v] // empty' 2>/dev/null); then
    published=""
  fi
  if [[ -n "$published" ]]; then
    if ! age_s=$(python3 -c "
import datetime, sys
pub = datetime.datetime.fromisoformat(sys.argv[1].replace('Z', '+00:00'))
print(int((datetime.datetime.now(datetime.timezone.utc) - pub).total_seconds()))
" "$published" 2>&1); then
      echo "BLOCKED: $name — release-age computation failed ($age_s); failing closed"
      fail=1
      continue
    fi
    if (( age_s < 86400 )); then
      echo "grace: $name@$latest is younger than the 24h release floor"
      continue
    fi
  fi
  echo "BLOCKED: $name is outdated (latest: $latest)"
  fail=1
done < <(jq -r 'to_entries[] | [.key, .value.latest] | @tsv' <<<"$pnpm_json")

echo
echo "=== mix hex.outdated ==="
# hex.outdated exits 1 when updates exist; breakage shows as a
# missing table header rather than a usable exit code.
hex_out=$(mix hex.outdated 2>&1)
hex_rc=$?
echo "$hex_out"
if ! grep -q "^Dependency" <<<"$hex_out"; then
  echo "scripts/outdated.sh: mix hex.outdated produced no dependency table (exit $hex_rc) — cannot verify Hex deps."
  exit 1
fi
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

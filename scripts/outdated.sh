#!/usr/bin/env bash
# Dependency gate: pre-push fails while any JS or Hex dependency is
# behind its latest release, except exempted releases and JS
# releases younger than the 24h supply-chain floor (minimumReleaseAge
# in pnpm-workspace.yaml — too young to be installable, so not yet
# actionable). It also fails on a missing or malformed
# scripts/dep-exemptions.json, and on a stale entry there. The gate
# fails CLOSED on its own breakage: missing tools, unreachable
# registries, or unparseable probe output block the push rather than
# skipping a check.

set -uo pipefail

cd "$(dirname "$0")/.."

prefix="scripts/outdated.sh:"
source scripts/deps-common.sh

require_tools pnpm jq mix python3 curl || exit 1

# An entry applies to both ecosystems, and scripts/bump-deps.sh skips
# the same releases. Once a newer release is out, or the package is
# current, the entry is stale and fails the gate.
load_exemptions || exit 1

# Exemption entries whose package is behind, whether or not the entry
# names its latest release; any other entry is for a current package.
matched=()

# exempt NAME LATEST: 0 when an entry covers exactly LATEST. An entry for
# any other release is reported stale; the caller then treats the
# package as outdated.
exempt() {
  local version reason
  version=$(exemption_version "$1")
  [[ -z "$version" ]] && return 1
  matched+=("$1")
  if [[ "$version" != "$2" ]]; then
    echo "stale exemption: $1 covers $version, but latest is $2"
    return 1
  fi
  reason=$(jq -r --arg n "$1" '.[$n].reason' <<<"$EXEMPT_JSON")
  echo "exempt: $1@$2 ($reason)"
}

for registry in https://registry.npmjs.org https://hex.pm; do
  curl -sf --max-time 5 "$registry" >/dev/null 2>&1 || {
    echo "scripts/outdated.sh: $registry unreachable — cannot verify dependencies are current."
    exit 1
  }
done

fail=0

echo "=== pnpm outdated (workspace) ==="
pnpm_outdated || exit 1
while IFS=$'\t' read -r name latest; do
  exempt "$name" "$latest" && continue
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
done < <(grep . <<<"$PNPM_ROWS")

echo
echo "=== mix hex.outdated ==="
hex_outdated || exit 1
echo "$HEX_OUT"
while read -r name latest _; do
  exempt "$name" "$latest" && continue
  echo "BLOCKED: $name is outdated (latest: $latest)"
  fail=1
done < <(grep . <<<"$HEX_ROWS")

while IFS= read -r name; do
  if [[ " ${matched[*]-} " != *" $name "* ]]; then
    echo "stale exemption: $name is not behind latest; remove its entry"
    fail=1
  fi
done < <(jq -r 'keys[]' <<<"$EXEMPT_JSON")

if [[ "$fail" != 0 ]]; then
  echo
  echo "scripts/outdated.sh: dependencies are behind latest, or an exemption"
  echo "is stale. Upgrade them and fix the fallout."
  exit 1
fi

echo
echo "all dependencies current."
exit 0

#!/usr/bin/env bash
# Dependency gate: pre-push fails while any JS or Hex dependency is
# behind its latest release, except exempted releases and releases too
# young to install, so not yet actionable: JS releases younger than the
# 24h supply-chain floor (minimumReleaseAge in pnpm-workspace.yaml), and
# Hex releases in the configured cooldown window that the requirements
# admit. Hex does not mark a cooldown release the requirements exclude,
# so that one blocks. A too-young release still makes an exemption for
# an older one stale. The gate also fails on every git dependency unless
# it has a stable Hex release and an exemption names the latest one, and
# on a missing or malformed scripts/dep-exemptions.json or a stale entry
# there. It fails CLOSED on its own breakage: missing tools, unreachable
# registries, or unparseable probe output block the push rather than
# skipping a check.

set -uo pipefail

cd "$(dirname "$0")/.."

prefix="scripts/outdated.sh:"
source scripts/deps-common.sh

require_tools pnpm jq mix curl || exit 1

# An entry applies to both ecosystems, and scripts/bump-deps.sh skips
# the same releases. Once a newer release is out, or the package is
# current, the entry is stale and fails the gate.
load_exemptions || exit 1

# Exemption entries whose package is behind, whether or not the entry
# names its latest release; any other entry is for a current package.
matched=()

# exempt NAME LATEST: 0 when an entry covers exactly LATEST. An entry for
# any other release is stale and fails the gate, even when LATEST is too
# young to require; the caller then checks the package as if unexempted.
exempt() {
  local version reason
  version=$(exemption_version "$1")
  [[ -z "$version" ]] && return 1
  matched+=("$1")
  if [[ "$version" != "$2" ]]; then
    echo "stale exemption: $1 covers $version, but latest is $2"
    fail=1
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
# An entry must name the registry's latest. pnpm's latest lags a release
# younger than the 24h floor, and pnpm leaves out a package installed at
# the newest release past the floor, so entries are checked against a
# report without the floor.
pnpm_outdated --config.minimum-release-age=0 || exit 1
exempted=()
while IFS=$'\t' read -r name latest; do
  exempt "$name" "$latest" && exempted+=("$name")
done < <(grep . <<<"$PNPM_ROWS")
# With the floor, pnpm reports only releases past it, so a release under
# 24h never blocks.
pnpm_outdated || exit 1
while IFS=$'\t' read -r name latest; do
  [[ " ${exempted[*]-} " == *" $name "* ]] && continue
  echo "BLOCKED: $name is outdated (latest: $latest)"
  fail=1
done < <(grep . <<<"$PNPM_ROWS")

echo
echo "=== mix hex.outdated ==="
hex_outdated || exit 1
echo "$HEX_OUT"
while read -r name latest status; do
  exempt "$name" "$latest" && continue
  if [[ "$status" == cooldown ]]; then
    echo "cooldown: $name@$latest is in the configured Hex cooldown window"
    continue
  fi
  echo "BLOCKED: $name is outdated (latest: $latest)"
  fail=1
done < <(grep . <<<"$HEX_ROWS")

# A git dependency is absent from hex.outdated's table, so nothing above
# would notice the Hex release that makes its pin unnecessary. Each one
# needs an entry naming the latest Hex release it replaces; a newer
# release makes the entry stale. scripts/bump-deps.sh never moves a git
# dependency, so a stale entry is updated by hand.
echo
echo "=== git dependencies ==="
if ! git_deps=$(sed -nE 's/^  "([a-z0-9_]+)": \{:git,.*/\1/p' mix.lock); then
  echo "scripts/outdated.sh: could not read mix.lock — cannot check git deps."
  exit 1
fi
while read -r name; do
  if ! latest=$(curl -sSf --max-time 10 "https://hex.pm/api/packages/$name" |
    jq -er '.latest_stable_version'); then
    echo "BLOCKED: $name — no latest Hex release found for this git dependency; failing closed"
    # Its entry was not checked, so it is not stale.
    matched+=("$name")
    fail=1
    continue
  fi
  exempt "$name" "$latest" && continue
  echo "BLOCKED: $name is a git dependency (latest Hex release: $latest);"
  echo "  add or update its exemption to name $latest, or depend on the Hex release"
  fail=1
done < <(grep . <<<"$git_deps")

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

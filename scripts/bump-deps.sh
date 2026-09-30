#!/usr/bin/env bash
# Pre-commit: moves each direct Hex and JS dependency that
# scripts/outdated.sh would report to its latest release, and stages the
# result into the commit, so no push fails for a dependency behind latest.
# Packages that are current are left alone, so a commit carries no
# lockfile change when nothing is behind.
#
# - Hex: a release outside mix.exs's requirement gets a new requirement
#   (scripts/bump-hex-requirements.exs); then `mix deps.update`.
# - JS: `pnpm -r update --latest`, which rewrites the package.json range
#   and keeps pnpm-workspace.yaml's minimumReleaseAge, so no release
#   younger than 24h enters the lockfile.
#
# A package whose latest release is the one its scripts/dep-exemptions.json
# entry names is left where it is. Any failure refuses the commit.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

files=(mix.exs mix.lock package.json pnpm-lock.yaml assets/package.json)

# An entry covers one release; a newer release is bumped to.
exempt=$(jq -r 'to_entries[] | "\(.key) \(.value.version)"' scripts/dep-exemptions.json)
is_exempt() { grep -qxF -- "$1 $2" <<<"$exempt"; }

# hex.outdated exits 1 when updates exist; breakage shows as a missing
# table header.
hex_out=$(mix hex.outdated 2>&1) || true
if ! grep -q "^Dependency" <<<"$hex_out"; then
  echo "$hex_out"
  echo "pre-commit: mix hex.outdated produced no dependency table; cannot bump Hex deps."
  exit 1
fi
hex_names=()
requirement_bumps=()
while read -r name latest status; do
  is_exempt "$name" "$latest" && continue
  hex_names+=("$name")
  [[ "$status" == not ]] && requirement_bumps+=("$name" "$latest")
done < <(awk '/Update possible/ {print $1, $(NF - 2), "possible"}
              /Update not possible/ {print $1, $(NF - 3), "not"}' <<<"$hex_out")

if [[ ${#requirement_bumps[@]} -gt 0 ]]; then
  elixir scripts/bump-hex-requirements.exs "${requirement_bumps[@]}"
fi
if [[ ${#hex_names[@]} -gt 0 ]]; then
  mix deps.update "${hex_names[@]}"
fi

# pnpm outdated exits 1 when it finds outdated deps; valid JSON is the
# success signal.
pnpm_json=$(pnpm -r outdated --format json 2>&1) || true
if ! jq empty <<<"$pnpm_json" 2>/dev/null; then
  echo "$pnpm_json"
  echo "pre-commit: pnpm outdated produced no JSON; cannot bump JS deps."
  exit 1
fi
js_names=()
while IFS=$'\t' read -r name latest; do
  is_exempt "$name" "$latest" || js_names+=("$name")
done < <(jq -r 'to_entries[] | [.key, .value.latest] | @tsv' <<<"$pnpm_json")
if [[ ${#js_names[@]} -gt 0 ]]; then
  pnpm -r update --latest --ignore-scripts "${js_names[@]}"
fi

if ! git diff --quiet -- "${files[@]}"; then
  git diff --stat -- "${files[@]}"
  git add -- "${files[@]}"
  echo "pre-commit: staged the dependency bump into this commit."
fi

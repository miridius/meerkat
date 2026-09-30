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
# Packages in scripts/dep-exemptions.json are left where they are. With
# unstaged edits to a dependency file the bump is skipped. Any failure
# refuses the commit.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

files=(mix.exs mix.lock package.json pnpm-lock.yaml assets/package.json)

# Staging would sweep unstaged edits to these files into the commit.
if ! git diff --quiet -- "${files[@]}"; then
  echo "pre-commit: dependency files have unstaged changes; skipping the dependency bump."
  exit 0
fi

exempt=$(jq -r 'keys[]' scripts/dep-exemptions.json)
is_exempt() { grep -qxF -- "$1" <<<"$exempt"; }

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
  is_exempt "$name" && continue
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
while IFS= read -r name; do
  is_exempt "$name" || js_names+=("$name")
done < <(jq -r 'keys[]' <<<"$pnpm_json")
if [[ ${#js_names[@]} -gt 0 ]]; then
  pnpm -r update --latest --ignore-scripts "${js_names[@]}"
fi

if ! git diff --quiet -- "${files[@]}"; then
  git diff --stat -- "${files[@]}"
  git add -- "${files[@]}"
  echo "pre-commit: staged the dependency bump into this commit."
fi

#!/usr/bin/env bash
# Pre-commit: moves each direct Hex and JS dependency that
# scripts/outdated.sh would report to its latest release, and stages the
# dependency files the bump changed into the commit. Packages that are
# current are left alone, so a commit carries no dependency change when
# nothing is behind.
#
# - Hex: a release outside mix.exs's requirement gets a new requirement
#   (scripts/bump-hex-requirements.exs); then `mix deps.update`. A
#   release another dependency holds back stays behind, and the pre-push
#   gate reports it.
# - JS: `pnpm -r update --latest`, which rewrites the package.json range
#   and keeps pnpm-workspace.yaml's minimumReleaseAge, so no release
#   younger than 24h enters the lockfile.
#
# A package whose latest release is the one its scripts/dep-exemptions.json
# entry names is left where it is. Any failure refuses the commit.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# A path commit (`git commit <path>`) commits from a temporary index, so
# a bump staged there would be missing from the real index afterwards,
# which would then hold its revert.
case "$(basename "${GIT_INDEX_FILE:-index}")" in
  index | index.lock) ;;
  *)
    echo "pre-commit: path commit; dependency bump deferred to the next full commit."
    exit 0
    ;;
esac

prefix="pre-commit:"
source scripts/deps-common.sh

require_tools jq mix elixir pnpm
load_exemptions

files=(mix.exs mix.lock package.json pnpm-lock.yaml assets/package.json)
before=()
for file in "${files[@]}"; do
  before+=("$(git hash-object -- "$file" 2>/dev/null || true)")
done

# An entry covers one release; a newer release is bumped to.
is_exempt() { [[ "$(exemption_version "$1")" == "$2" ]]; }

hex_outdated
hex_names=()
requirement_bumps=()
while read -r name latest status; do
  is_exempt "$name" "$latest" && continue
  hex_names+=("$name")
  [[ "$status" == not ]] && requirement_bumps+=("$name" "$latest")
done < <(grep . <<<"$HEX_ROWS")

if [[ ${#requirement_bumps[@]} -gt 0 ]]; then
  elixir scripts/bump-hex-requirements.exs "${requirement_bumps[@]}"
fi
if [[ ${#hex_names[@]} -gt 0 ]]; then
  mix deps.update "${hex_names[@]}"
fi

pnpm_outdated
js_names=()
while IFS=$'\t' read -r name latest; do
  is_exempt "$name" "$latest" || js_names+=("$name")
done < <(grep . <<<"$PNPM_ROWS")
if [[ ${#js_names[@]} -gt 0 ]]; then
  pnpm -r update --latest --ignore-scripts "${js_names[@]}"
fi

bumped=()
for i in "${!files[@]}"; do
  if [[ "$(git hash-object -- "${files[$i]}" 2>/dev/null || true)" != "${before[$i]}" ]]; then
    bumped+=("${files[$i]}")
  fi
done
if [[ ${#bumped[@]} -gt 0 ]]; then
  git diff --stat -- "${bumped[@]}"
  git add -- "${bumped[@]}"
  echo "pre-commit: staged the dependency bump into this commit."
fi

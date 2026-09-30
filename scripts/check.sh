#!/usr/bin/env bash
# Pre-commit gate: runs every check CI runs, in this checkout.
# `pnpm install --frozen-lockfile`, as in CI, also fails a commit whose
# pnpm-lock.yaml does not match its package.json files.
#
# A commit that changes only Markdown files, or nothing, skips the checks;
# CI still runs them on the PR.
#
# Emergency bypass: git commit --no-verify.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root"

# During `git commit -a` or `git commit <paths>`, GIT_INDEX_FILE names a
# temporary index holding the commit's contents, so read it before
# clearing git's environment. --no-renames lists a renamed file's old path
# too, so renaming code to *.md still runs the checks.
changed=$(git diff --cached --no-renames --name-only)
if [[ -z "$changed" ]] || ! grep -qv '\.md$' <<<"$changed"; then
  echo "pre-commit: no files other than Markdown changed; skipping checks."
  exit 0
fi

# Git exports GIT_INDEX_FILE and friends to hooks; left set, they would
# point every test's fixture repo at this checkout's index.
# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars)

step() {
  echo
  echo "=== pre-commit: $* ==="
  "$@"
}

step mix deps.get
step pnpm install --frozen-lockfile --ignore-scripts --prefer-offline
step mix compile --warnings-as-errors
step mix format --check-formatted
step mix credo --strict
step bunx biome lint --error-on-warnings
step mix test
(cd assets && step bun test)
(cd assets && MIX_BUILD_PATH="$root/_build/dev" step bun run build)
step bunx playwright install --only-shell chromium
step bun run test:e2e

echo
echo "=== pre-commit: all checks passed ==="

#!/usr/bin/env bash
# Pre-commit gate: runs every check CI runs against exactly the snapshot
# being committed. The staged tree is checked out
# into a throwaway linked worktree, so unstaged edits and untracked files
# in this checkout can neither rescue nor sink the commit. deps/ and
# _build/ are copied in to keep compilation incremental; node_modules
# comes from `pnpm install --frozen-lockfile`, as in CI, which also fails
# a commit whose pnpm-lock.yaml does not match its package.json files.
#
# A commit that changes only Markdown files, or nothing, skips the checks;
# CI still runs them on the PR.
#
# Run outside a hook, it checks whatever is staged in the index.
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
tree=$(git write-tree)

# Git exports GIT_DIR, GIT_INDEX_FILE and friends to hooks; left set, they
# would point `git worktree add` and every test's fixture repo at this
# checkout's index.
# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars)

parent=()
if head=$(git rev-parse -q --verify HEAD); then
  parent=(-p "$head")
fi
commit=$(git commit-tree "${parent[@]}" -m "pre-commit snapshot" "$tree")

snap=$(mktemp -d "${TMPDIR:-/tmp}/meerkat-precommit.XXXXXX")
cleanup() {
  git -C "$root" worktree remove --force "$snap" 2>/dev/null || rm -rf "$snap"
  git -C "$root" worktree prune
}
trap cleanup EXIT

# No hooks: the post-checkout hook would otherwise fire for the snapshot.
git -c core.hooksPath=/dev/null worktree add --quiet --detach "$snap" "$commit"
for dir in deps _build; do
  if [[ -d "$dir" ]]; then
    cp -R "$dir" "$snap/$dir"
  fi
done
cd "$snap"

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
(cd assets && MIX_BUILD_PATH="$snap/_build/dev" step bun run build)
step bunx playwright install --only-shell chromium
step bun run test:e2e

echo
echo "=== pre-commit: all checks passed ==="

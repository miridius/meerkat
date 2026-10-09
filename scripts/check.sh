#!/usr/bin/env bash
# Pre-commit gate: runs every check CI runs, in this checkout.
# `pnpm install --frozen-lockfile`, as in CI, also fails a commit whose
# pnpm-lock.yaml does not match its package.json files.
#
# `check.sh --head`, run by scripts/verified-push.sh, checks HEAD instead
# of the commit being made.
#
# In pre-commit mode, a commit that changes only Markdown files, or nothing,
# skips the checks; CI still runs them on the PR. Otherwise the checks wait
# for a slot from scripts/gate-lock.sh.
#
# When the checks pass and the worktree held exactly the contents checked,
# with no untracked file, both when they started and when they finished,
# scripts/checked-trees.sh records those contents.
set -euo pipefail

# Stop at Ctrl-C, however the interrupted step exited: bash carries on after
# a child that handled SIGINT itself, as the BEAM does, and the run could
# then go on to record contents whose checks never finished. Dying by SIGINT,
# not exiting, makes a calling bash stop too.
trap 'trap - INT; kill -INT $$' INT

root=$(git rev-parse --show-toplevel)
cd "$root"

if [[ "${1:-}" == --head ]]; then
  label=pre-push
  # Resolved now: HEAD can move while the checks run.
  tree=$(git rev-parse --verify 'HEAD^{tree}')
else
  label=pre-commit
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
fi

holds() { bash scripts/checked-trees.sh holds "$tree"; }

step() {
  echo
  echo "=== $label: $* ==="
  "$@"
}

run_checks() {
  holds && clean=1 || clean=0

  # Git exports GIT_INDEX_FILE and friends to hooks; left set, they would
  # point every test's fixture repo at this checkout's index.
  # shellcheck disable=SC2046
  unset $(git rev-parse --local-env-vars)

  step mix deps.get
  step pnpm install --frozen-lockfile --ignore-scripts --prefer-offline
  step mix compile --warnings-as-errors
  step mix format --check-formatted
  step mix credo --strict
  step bunx biome lint --error-on-warnings
  step bash scripts/mix-test.sh
  (cd assets && step bun test)
  step bun test tests/e2e/lib
  (cd assets && MIX_BUILD_PATH="$root/_build/dev" step bun run build)
  step bunx playwright install --only-shell chromium
  step bun run test:e2e

  # Checked again in case the worktree changed while the checks ran.
  if [[ "$clean" == 1 ]] && holds; then
    bash scripts/checked-trees.sh mark "$tree"
  fi

  echo
  echo "=== $label: all checks passed ==="
}

# At most two gates in all of this repo's worktrees run the checks at once.
# This shell holds the slot until it exits. The checks run in a subshell
# that closes the slot's fd first, so nothing they start can keep the slot
# once this shell is gone; `run_checks 9>&-` would not do, as bash keeps a
# copy of fd 9 that its subshells, and under bash 3.2 every child, inherit.
# The subshell resets the INT trap, so it gets one that ends it at Ctrl-C,
# after which this shell's own trap stops this script.
source scripts/gate-lock.sh
gate_lock
(
  exec 9>&-
  trap 'exit 130' INT
  run_checks
)

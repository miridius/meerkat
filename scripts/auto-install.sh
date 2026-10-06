#!/usr/bin/env bash
# Shared guard for the lefthook post-merge / post-checkout hooks:
# (re)install meerkat, and refresh the dev and test envs' deps and builds, only
# when HEAD is on `main`. `install.sh` is
# idempotent (it skips the rebuild when the release is already built
# from the current commit), so firing this on every `main` checkout is
# cheap — only a genuine commit change triggers the minutes-long build.
#
# Why two hooks: `post-merge` catches `git pull` / `git merge`;
# `post-checkout` catches `git switch main` / `git checkout main` — the
# path a GitHub squash-merge takes, since it lands on origin/main,
# never a local merge. `git fetch origin main:main` and `git reset`
# fire neither hook, so run scripts/install.sh after them.
set -euo pipefail

cd "$(dirname "$0")/.."

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo)"
case "$branch" in
  main)
    bash scripts/install.sh
    # install.sh builds only prod. New Claude worktrees copy main's deps/
    # and _build/ (see .worktreeinclude), so also bring the dev and test
    # envs up to date. The copy is newer than the worktree's sources, so
    # bin/meerkat-beam would not rebuild a stale dev build. Git exports
    # GIT_DIR and friends to hooks; left set, they would point git
    # dependencies' checkouts at this repository.
    (
      # shellcheck disable=SC2046
      unset $(git rev-parse --local-env-vars)
      for env in dev test; do
        MIX_ENV=$env mix deps.get
        MIX_ENV=$env mix compile
      done
    )
    ;;
  "")
    echo "meerkat auto-install: couldn't resolve HEAD; skipping." >&2
    ;;
  *)
    echo "meerkat auto-install: HEAD=$branch (not main); skipping." >&2
    ;;
esac

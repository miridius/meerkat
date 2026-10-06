#!/usr/bin/env bash
# Shared guard for the lefthook post-merge / post-checkout hooks:
# (re)install meerkat and the public-root pre-push hook only when HEAD
# is on `main`. `install.sh` is
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
    # Keep the clone's installed public-root hook the same as main's.
    status=0
    bash scripts/public-root.sh --install || status=1
    bash scripts/install.sh
    exit "$status"
    ;;
  "")
    echo "meerkat auto-install: couldn't resolve HEAD; skipping." >&2
    ;;
  *)
    echo "meerkat auto-install: HEAD=$branch (not main); skipping." >&2
    ;;
esac

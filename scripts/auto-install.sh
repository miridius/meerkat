#!/usr/bin/env bash
# Shared guard for the lefthook post-merge / post-checkout hooks:
# (re)install meerkat only when HEAD is on `main`. `install.sh` is
# idempotent (it skips the rebuild when the release is already built
# from the current commit), so firing this on every `main` checkout is
# cheap — only a genuine commit change triggers the minutes-long build.
#
# Why two hooks: `post-merge` catches `git pull` / `git merge`;
# `post-checkout` catches `git switch main` / `git checkout main` — the
# path a GitHub squash-merge takes, since it lands on origin/main and
# local main is brought to it by switching/resetting, never a local
# merge. Together they cover every way local `main` advances.
set -euo pipefail

cd "$(dirname "$0")/.."

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo)"
case "$branch" in
  main)
    bash scripts/install.sh
    ;;
  "")
    echo "meerkat auto-install: couldn't resolve HEAD; skipping." >&2
    ;;
  *)
    echo "meerkat auto-install: HEAD=$branch (not main); skipping." >&2
    ;;
esac

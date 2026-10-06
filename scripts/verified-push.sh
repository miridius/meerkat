#!/usr/bin/env bash
# Pre-push check: every commit pushed as a ref's new tip must have contents
# that passed scripts/check.sh, as scripts/checked-trees.sh records them.
# A rebase, merge or cherry-pick makes a commit without running the
# pre-commit hook, so without this its contents would reach CI unchecked.
#
#   verified-push.sh <sha>...
#
# An unchecked tip that is HEAD, with nothing uncommitted or untracked, is
# checked now with `check.sh --head`. Any other unchecked tip is refused:
# check it out and push again.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)"

status=0
for sha in "$@"; do
  # A tag can point at something other than a commit; only commits are built.
  # Anything git cannot read is refused rather than skipped.
  if ! object=$(git rev-parse --verify --quiet "$sha^{}") ||
    ! type=$(git cat-file -t "$object"); then
    echo "pre-push: cannot read $sha." >&2
    status=1
    continue
  fi
  [[ "$type" == commit ]] || continue
  commit=$object
  bash scripts/checked-trees.sh has "$commit" && continue

  short=$(git rev-parse --short "$commit")
  if [[ "$commit" != "$(git rev-parse HEAD)" ]]; then
    echo "pre-push: $short has not passed scripts/check.sh. Check it out and push again." >&2
    status=1
  elif ! bash scripts/checked-trees.sh holds "$commit"; then
    echo "pre-push: HEAD ($short) has not passed scripts/check.sh, and the worktree has" >&2
    echo "uncommitted or untracked files, so it cannot be checked as committed." >&2
    echo "Commit or remove them, then push again." >&2
    status=1
  else
    echo "pre-push: HEAD ($short) has not passed scripts/check.sh since it was made" >&2
    echo "(a rebase, merge or cherry-pick skips the pre-commit hook); checking it now." >&2
    if ! bash scripts/check.sh --head; then
      status=1
    elif ! bash scripts/checked-trees.sh has "$commit"; then
      # check.sh records nothing when the worktree changed while it ran.
      echo "pre-push: the worktree changed while HEAD ($short) was being checked." >&2
      echo "Push again once it holds exactly HEAD." >&2
      status=1
    fi
  fi
done
exit "$status"

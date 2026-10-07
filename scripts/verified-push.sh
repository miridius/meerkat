#!/usr/bin/env bash
# Pre-push check: every commit pushed as a ref's new tip must have contents
# that passed scripts/check.sh, as scripts/checked-trees.sh records them.
# A rebase, merge or cherry-pick makes a commit without running the
# pre-commit hook, so without this its contents would reach CI unchecked.
#
#   verified-push.sh <sha>...
#
# An unchecked tip that is HEAD, with nothing uncommitted or untracked, is
# checked now with `check.sh --head`. An unchecked HEAD in a worktree holding
# anything else is refused. Any other unchecked tip, such as a branch below
# HEAD that `gh stack sync` rebased and pushes with it, is checked with
# `check.sh --head` in a temporary worktree of that commit.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)"

# check_elsewhere <commit>: runs that commit's `check.sh --head` in a new
# detached worktree, which builds everything from scratch, then removes it,
# even when the check is interrupted.
check_elsewhere() (
  tmp=$(mktemp -d) || exit 1
  # Bash also runs this when a signal such as Ctrl-C's kills it.
  trap '[ ! -e "$tmp/tree" ] || git worktree remove --force "$tmp/tree"; rm -rf "$tmp"' EXIT
  # No hooks: post-checkout would run lefthook, which the new worktree lacks.
  git -c core.hooksPath=/dev/null worktree add -q --detach "$tmp/tree" "$1" || exit 1
  cd "$tmp/tree" || exit 1
  # Git exports GIT_DIR and friends to hooks; left set, they would point
  # the check's git commands at this checkout instead.
  # shellcheck disable=SC2046
  unset $(git rev-parse --local-env-vars)
  bash scripts/check.sh --head
)

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
    echo "pre-push: $short has not passed scripts/check.sh; checking it now in a" >&2
    echo "temporary worktree." >&2
    if ! check_elsewhere "$commit"; then
      echo "pre-push: $short failed scripts/check.sh." >&2
      status=1
    elif ! bash scripts/checked-trees.sh has "$commit"; then
      echo "pre-push: $short passed scripts/check.sh but was not recorded." >&2
      status=1
    fi
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

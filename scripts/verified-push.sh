#!/usr/bin/env bash
# Pre-push check: every commit pushed as a ref's new tip must have contents
# that passed scripts/check.sh and the mutation gate of scripts/mutate.sh, as
# scripts/checked-trees.sh records them. A rebase or cherry-pick makes a
# commit without running the pre-commit hook, and git runs no hook that can
# refuse a finished rebase, so without this its contents would reach CI
# unchecked and its lib lines, conflict resolutions included, unmutated.
#
# Merge commits are refused before any gate runs: branches take in main by
# rebasing. A push is refused when it brings a commit with more than one
# parent that no remote-tracking ref holds.
#
#   verified-push.sh <sha>...
#
# An unchecked tip that is HEAD, with nothing uncommitted or untracked, is
# checked now. An unchecked HEAD in a worktree holding anything else is
# refused. Any other unchecked tip, such as a branch below HEAD that
# `gh stack sync` rebased and pushes with it, is checked in a temporary
# worktree of that commit.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)"

# Whether commit $1's contents passed both gates.
gated() {
  bash scripts/checked-trees.sh has "$1" && bash scripts/checked-trees.sh --mutated has "$1"
}

# run_gates <commit>: runs, on the checkout of that commit, each gate its
# contents have not passed: `check.sh --head`, then `mutate.sh changed`
# against origin/main, which mutates every lib line the commit changed since
# main. If check.sh fails, mutate.sh is not run.
run_gates() {
  if ! bash scripts/checked-trees.sh has "$1"; then
    bash scripts/check.sh --head || return 1
  fi
  if ! bash scripts/checked-trees.sh --mutated has "$1"; then
    BASE_BRANCH=origin/main bash scripts/mutate.sh changed || return 1
  fi
}

# check_elsewhere <commit>: runs that commit's gates in a new detached
# worktree, which builds everything from scratch, then removes it, even when
# a gate is interrupted.
check_elsewhere() (
  tmp=$(mktemp -d) || exit 1
  # A second Ctrl-C does not cut the cleanup short.
  trap 'trap "" INT; [ ! -e "$tmp/tree" ] || git worktree remove --force "$tmp/tree"; rm -rf "$tmp"' EXIT
  # An exit, not death by SIGINT: bash 3.2 can skip the EXIT trap then.
  trap 'exit 130' INT
  # No hooks: post-checkout would run lefthook, which the new worktree lacks.
  git -c core.hooksPath=/dev/null worktree add -q --detach "$tmp/tree" "$1" || exit 1
  cd "$tmp/tree" || exit 1
  # Git exports GIT_DIR and friends to hooks; left set, they would point
  # the check's git commands at this checkout instead.
  # shellcheck disable=SC2046
  unset $(git rev-parse --local-env-vars)
  run_gates "$1"
)

# Stop at Ctrl-C, however the interrupted child exited: bash carries on after
# a child that handled SIGINT itself, as the BEAM does. Dying by SIGINT, not
# exiting, makes a calling bash stop too.
trap 'trap - INT; kill -INT $$' INT

status=0
commits=()
for sha in "$@"; do
  # A tag can point at something other than a commit; only commits are built.
  # Anything git cannot read is refused rather than skipped.
  if ! object=$(git rev-parse --verify --quiet "$sha^{}") ||
    ! type=$(git cat-file -t "$object"); then
    echo "pre-push: cannot read $sha." >&2
    status=1
    continue
  fi
  [[ "$type" == commit ]] && commits+=("$object")
done
[[ ${#commits[@]} -gt 0 ]] || exit "$status"

# A stale remote-tracking ref can only make this refuse more: a merge the
# remote already holds is let through once `git fetch` has brought it.
if ! merges=$(git rev-list --min-parents=2 "${commits[@]}" --not --remotes); then
  echo "pre-push: cannot list the commits being pushed." >&2
  exit 1
fi
if [[ -n "$merges" ]]; then
  echo "pre-push: merge commits are refused; rebase onto main instead:" >&2
  # shellcheck disable=SC2086
  git log --no-walk --format='  %h %s' $merges >&2
  exit 1
fi

for commit in "${commits[@]}"; do
  gated "$commit" && continue

  short=$(git rev-parse --short "$commit")
  if [[ "$commit" != "$(git rev-parse HEAD)" ]]; then
    echo "pre-push: $short has not passed the commit gate; checking it now in a" >&2
    echo "temporary worktree." >&2
    if ! check_elsewhere "$commit"; then
      echo "pre-push: $short failed the commit gate." >&2
      status=1
    elif ! gated "$commit"; then
      echo "pre-push: $short passed the commit gate but was not recorded." >&2
      status=1
    fi
  elif ! bash scripts/checked-trees.sh holds "$commit"; then
    echo "pre-push: HEAD ($short) has not passed the commit gate, and the worktree has" >&2
    echo "uncommitted or untracked files, so it cannot be checked as committed." >&2
    echo "Commit or remove them, then push again." >&2
    status=1
  else
    echo "pre-push: HEAD ($short) has not passed the commit gate since it was made" >&2
    echo "(a rebase or cherry-pick skips the pre-commit hook); checking it now." >&2
    if ! run_gates "$commit"; then
      status=1
    elif ! gated "$commit"; then
      # Neither gate records anything when the worktree changed while it ran.
      echo "pre-push: the worktree changed while HEAD ($short) was being checked." >&2
      echo "Push again once it holds exactly HEAD." >&2
      status=1
    fi
  fi
done
exit "$status"

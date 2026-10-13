#!/usr/bin/env bash
# Land PRs one at a time, like a merge queue: scripts/merge-queue.sh <PR>[@<sha>]...
#
# With @<sha>, the PR is landed only at that reviewed commit, or at this
# script's own rebase of it. Without one, the head first read is pinned.
#
# main requires green checks on a branch up to date with main. For each PR in
# order: rebase a behind branch onto its base locally and push it (see
# rebase_onto_base), wait for every check on the head, squash-merge with the
# head pinned only if none failed, and delete the remote branch. Merges go
# through GitHub's asynchronous merge API, which GitHub requires for PRs in a
# stack. Prints one line per landed PR. At the first PR it cannot land, it
# prints the reason (with gh's or git's output when there is any), then
# `not attempted:` and the remaining arguments, and exits 1. Each wait for
# GitHub gives up after MERGE_QUEUE_TIMEOUT seconds.
set -uo pipefail

poll=${MERGE_QUEUE_POLL:-15}
timeout=${MERGE_QUEUE_TIMEOUT:-600}

fail() {
  echo "#$pr $1"
  [ -n "${2:-}" ] && printf '%s\n' "$2"
  echo "not attempted:${rest[*]:+ ${rest[*]}}"
  exit 1
}

# Sleep one poll interval, or stop the queue once the caller's $deadline passed.
wait_for() {
  [ "$SECONDS" -lt "$deadline" ] || fail "timed out waiting for $1"
  sleep "$poll"
}

# The temporary worktree rebase_onto_base works in, removed however the
# script ends.
tmp=""
cleanup() {
  [ -n "$tmp" ] || return 0
  [ ! -e "$tmp/tree" ] || git worktree remove --force "$tmp/tree" >/dev/null 2>&1
  rm -rf "$tmp"
  tmp=""
}
trap cleanup EXIT

# Rebase $branch, pinned at $head, onto origin/$base in a temporary worktree,
# set $rebased to the rebased head, and push it with a lease on $head. The
# push runs the pre-push hook, so the rebased commits pass the same gates as
# any other push, mutation testing included. Merge commits are refused there,
# and the rebase drops any the branch had. GitHub's update-branch would
# bring main in on GitHub, where no local gate runs.
rebase_onto_base() {
  local out
  out=$(git fetch -q origin "+refs/heads/$base:refs/remotes/origin/$base" \
    "+refs/heads/$branch:refs/remotes/origin/$branch" 2>&1) || fail "could not be fetched" "$out"
  tmp=$(mktemp -d) || fail "could not make a temporary worktree"
  # Hooks are off until the push: the worktree lacks the lefthook that the
  # checkout and commit hooks call.
  if ! out=$(git -c core.hooksPath=/dev/null worktree add -q --detach "$tmp/tree" "$head" 2>&1); then
    fail "could not be checked out at $head" "$out"
  fi
  if ! out=$(git -C "$tmp/tree" -c core.hooksPath=/dev/null rebase "origin/$base" 2>&1); then
    local conflicts
    conflicts=$(git -C "$tmp/tree" diff --name-only --diff-filter=U)
    git -C "$tmp/tree" rebase --abort >/dev/null 2>&1
    [ -n "$conflicts" ] || fail "could not be rebased onto $base" "$out"
    fail "conflicts with $base" "$out"
  fi
  rebased=$(git -C "$tmp/tree" rev-parse HEAD)
  # The pre-push hook runs the worktree's own lefthook, and its dependency
  # check reads deps/, so the worktree is set up as check.sh sets one up.
  out=$(cd "$tmp/tree" && mix deps.get 2>&1 &&
    pnpm install --frozen-lockfile --ignore-scripts --prefer-offline 2>&1) ||
    fail "could not be set up to push" "$(tail -n 40 <<<"$out")"
  # The gates print thousands of lines; their end says what failed.
  out=$(git -C "$tmp/tree" push --force-with-lease="refs/heads/$branch:$head" origin \
    "HEAD:refs/heads/$branch" 2>&1) || fail "rebase onto $base could not be pushed" "$(tail -n 40 <<<"$out")"
  cleanup
}

land() {
  local state head merge_state checks branch base out expected=$reviewed updated_from="" note="" rebased
  local deadline=$((SECONDS + timeout))
  while :; do
    out=$(gh pr view "$pr" \
      --json state,headRefOid,headRefName,baseRefName,mergeStateStatus,statusCheckRollup \
      -q '[.state, .headRefOid, .headRefName, .baseRefName, .mergeStateStatus,
           (.statusCheckRollup | length)] | @tsv' 2>&1) || fail "could not be read" "$out"
    IFS=$'\t' read -r state head branch base merge_state checks <<<"$out"
    [ -n "${head:-}" ] || fail "could not be read" "$out"
    [ "$state" = OPEN ] || fail "is $state"

    # GitHub can report the head from before the rebase was pushed for a while.
    if [ -n "$updated_from" ] && [ "$head" = "$updated_from" ]; then
      wait_for "GitHub to see the rebased head"
      continue
    fi
    [ -n "$expected" ] || expected=$head
    [ "$head" = "$expected" ] || fail "head moved from $expected to $head"

    case $merge_state in
      UNKNOWN)
        wait_for "GitHub to compute mergeability"
        continue
        ;;
      DIRTY)
        fail "conflicts with $base" "$(gh pr view "$pr" --json url,headRefName,mergeable,mergeStateStatus)"
        ;;
      BEHIND)
        rebase_onto_base
        updated_from=$head
        expected=$rebased
        deadline=$((SECONDS + timeout))
        note=" (rebased onto $base)"
        continue
        ;;
    esac
    # `gh pr checks` fails when the head has no checks yet.
    if [ "$checks" = 0 ]; then
      wait_for "checks to register"
      continue
    fi

    if ! out=$(gh pr checks "$pr" --watch --fail-fast --interval "$poll" 2>&1); then
      # A non-zero exit is also how gh reports an API error, so only a check
      # in gh's `fail` bucket counts as a failure.
      checks=$(gh pr checks "$pr" 2>&1)
      if grep -q $'\tfail\t' <<<"$checks"; then fail "checks failed" "$checks"; fi
      fail "checks could not be watched" "$out"
    fi
    out=$(gh pr view "$pr" --json headRefOid -q .headRefOid 2>&1) || fail "could not be read" "$out"
    [ "$out" = "$head" ] || fail "head moved from $head to $out"
    squash_merge
    gh api -X DELETE "repos/{owner}/{repo}/git/refs/heads/$branch" >/dev/null 2>&1 ||
      note+=" (remote branch $branch not deleted)"
    echo "#$pr merged $merged$note"
    return
  done
}

# Squash-merge $pr at $head and set $merged to the squash commit. GitHub's
# asynchronous merge API is the one that also merges a PR in a stack; it would
# land the open PRs below one too, so those are refused first.
squash_merge() {
  local below status uuid deadline
  below=$(gh api "repos/{owner}/{repo}/pulls/$pr" --jq '.stack // empty
    | "\(.id) \(.position)"' 2>&1) || fail "could not be read" "$below"
  if [ -n "$below" ]; then
    below=$(gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --paginate --jq ".[]
      | select(.stack.id == ${below% *} and .stack.position < ${below#* }) | \"#\(.number)\"" 2>&1) ||
      fail "could not be read" "$below"
    [ -z "$below" ] || fail "has open PRs below it in its stack: ${below//$'\n'/ }"
  fi

  out=$(gh api -X PUT "repos/{owner}/{repo}/pulls/$pr/merge-async" -f sha="$head" \
    -f merge_method=squash -f merge_action=direct_merge 2>&1) || fail "merge refused" "$out"
  deadline=$((SECONDS + timeout))
  while :; do
    status=$(jq -er .status <<<"$out" 2>/dev/null) || fail "merge result could not be read" "$out"
    [ "$status" = pending ] || break
    wait_for "GitHub to finish the merge"
    uuid=$(jq -er .details.uuid <<<"$out" 2>/dev/null) || fail "merge result could not be read" "$out"
    out=$(gh api "repos/{owner}/{repo}/pulls/$pr/merge-async/$uuid" 2>&1) ||
      fail "merge status could not be read" "$out"
  done
  [ "$status" = merged ] || fail "merge refused" "$out"
  merged=$(jq -er .details.sha <<<"$out" 2>/dev/null) || fail "merge result could not be read" "$out"
}

[ $# -gt 0 ] || { echo "usage: $0 <PR>[@<sha>]..." >&2; exit 2; }
rest=("$@")
while [ ${#rest[@]} -gt 0 ]; do
  pr=${rest[0]%@*}
  reviewed=""
  [[ ${rest[0]} == *@* ]] && reviewed=${rest[0]#*@}
  rest=("${rest[@]:1}")
  land
done

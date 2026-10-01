#!/usr/bin/env bash
# Land PRs one at a time, like a merge queue: scripts/merge-queue.sh <PR>[@<sha>]...
#
# With @<sha>, the PR is landed only at that reviewed commit, or at GitHub's
# own merge of main into it. Without one, the head first read is pinned.
#
# main requires green checks on a branch up to date with main, and signed
# commits. For each PR in order: merge main into a behind branch on GitHub
# (`gh pr update-branch`; GitHub signs that merge commit, while `--rebase`
# would leave the rewritten commits unsigned), wait for every check on the
# head, squash-merge with the head pinned only if none failed (GitHub signs
# the squash commit), and delete the remote branch. Merges go through GitHub's
# asynchronous merge API, which GitHub requires for PRs in a stack. Prints one
# line per landed PR. At the first PR it cannot land, it prints the reason
# (with gh's output when there is any), then `not attempted:` and the remaining
# arguments, and exits 1; a HUP, INT or TERM signal stops it the same way.
# Each wait for GitHub gives up after MERGE_QUEUE_TIMEOUT seconds.
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

land() {
  local state head merge_state checks branch out expected=$reviewed updated_from="" note=""
  local deadline=$((SECONDS + timeout))
  while :; do
    out=$(gh pr view "$pr" \
      --json state,headRefOid,headRefName,mergeStateStatus,statusCheckRollup \
      -q '[.state, .headRefOid, .headRefName, .mergeStateStatus,
           (.statusCheckRollup | length)] | @tsv' 2>&1) || fail "could not be read" "$out"
    IFS=$'\t' read -r state head branch merge_state checks <<<"$out"
    [ -n "${head:-}" ] || fail "could not be read" "$out"
    [ "$state" = OPEN ] || fail "is $state"

    if [ -n "$updated_from" ] && [ "$head" = "$updated_from" ]; then
      wait_for "the update with main"
      continue
    fi
    [ -n "$expected" ] || expected=$head
    if [ "$head" != "$expected" ]; then
      # Accept a new head only as GitHub's signed merge of main into the pinned
      # one, whether this run asked for it or an interrupted earlier run did.
      out=$(gh api "repos/{owner}/{repo}/commits/$head" --jq '.commit.verification.verified,
        .commit.verification.reason, .committer.login, .parents[].sha' 2>&1) ||
        fail "head $head could not be read" "$out"
      if [ "$(sed -n 3p <<<"$out")" != web-flow ] || ! grep -qxF "$expected" <<<"$out"; then
        [ -n "$updated_from" ] || fail "head moved from $expected to $head"
        fail "head $head is not GitHub's update of $expected" "$out"
      fi
      [ "$(sed -n 1p <<<"$out")" = true ] || fail "update commit $head is not verified" "$out"
      expected=$head
      note=" (updated with main)"
    fi
    updated_from=""

    case $merge_state in
      UNKNOWN)
        wait_for "GitHub to compute mergeability"
        continue
        ;;
      DIRTY)
        fail "conflicts with main" "$(gh pr view "$pr" --json url,headRefName,mergeable,mergeStateStatus)"
        ;;
      BEHIND)
        out=$(gh pr update-branch "$pr" 2>&1) || fail "update with main refused" "$out"
        updated_from=$head
        deadline=$((SECONDS + timeout))
        note=" (updated with main)"
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
  for sig in HUP INT TERM; do trap "fail 'stopped by SIG$sig'" "$sig"; done
  land
done

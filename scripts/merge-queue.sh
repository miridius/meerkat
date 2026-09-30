#!/usr/bin/env bash
# Land PRs one at a time, like a merge queue: scripts/merge-queue.sh <PR>[@<sha>]...
#
# With @<sha>, the PR is landed only if its head is still that reviewed commit.
#
# main requires green checks on a branch up to date with main, and signed
# commits. For each PR in order: merge main into a behind branch on GitHub
# (`gh pr update-branch`; GitHub signs that merge commit, while `--rebase`
# would leave the rewritten commits unsigned), wait for every check on the
# head, squash-merge with the head pinned only if none failed (GitHub signs
# the squash commit), and delete the remote branch. Merges go through GitHub's
# asynchronous merge API, since its GraphQL merge refuses PRs in a stack. Prints one line per PR and
# stops at the first PR it cannot land, with the gh output explaining why.
set -uo pipefail

poll=${MERGE_QUEUE_POLL:-15}

fail() {
  echo "#$pr $1"
  [ -n "${2:-}" ] && printf '%s\n' "$2"
  echo "not attempted: ${rest[*]:-none}"
  exit 1
}

land() {
  local state head merge_state checks branch out updated_from="" note=""
  while :; do
    IFS=$'\t' read -r state head branch merge_state checks < <(gh pr view "$pr" \
      --json state,headRefOid,headRefName,mergeStateStatus,statusCheckRollup \
      -q '[.state, .headRefOid, .headRefName, .mergeStateStatus,
           (.statusCheckRollup | length)] | @tsv' 2>/dev/null)
    [ -n "${head:-}" ] || fail "could not be read" "$(gh pr view "$pr" 2>&1)"
    [ "$state" = OPEN ] || fail "is $state"
    if [ -n "$reviewed" ]; then
      [ "$head" = "$reviewed" ] || fail "head $head is not the reviewed $reviewed"
      reviewed=""
    fi

    # Wait for the update's new head, for GitHub to compute mergeability, and
    # for the head's checks to register (`gh pr checks` fails when it has none).
    if [ "$head" = "$updated_from" ] || [ "$merge_state" = UNKNOWN ] || [ "$checks" = 0 ]; then
      sleep "$poll"
      continue
    fi
    if [ -n "$updated_from" ]; then
      out=$(gh api "repos/{owner}/{repo}/commits/$head" --jq '.commit.verification | "verified: \(.verified), reason: \(.reason)"' 2>&1)
      [[ $out == "verified: true,"* ]] || fail "update commit $head is not verified" "$out"
      updated_from=""
    fi

    case $merge_state in
      DIRTY)
        fail "conflicts with main" "$(gh pr view "$pr" --json url,headRefName,mergeable,mergeStateStatus)"
        ;;
      BEHIND)
        out=$(gh pr update-branch "$pr" 2>&1) || fail "update with main refused" "$out"
        updated_from=$head
        note=" (updated with main)"
        continue
        ;;
    esac

    if ! out=$(gh pr checks "$pr" --watch --fail-fast --interval "$poll" 2>&1); then
      # A non-zero exit is also how gh reports an API error, so only a check
      # in gh's `fail` bucket counts as a failure.
      checks=$(gh pr checks "$pr" 2>&1)
      if grep -q $'\tfail\t' <<<"$checks"; then fail "checks failed" "$checks"; fi
      fail "checks could not be watched" "$out"
    fi
    out=$(gh pr view "$pr" --json headRefOid -q .headRefOid 2>&1)
    [ "$out" = "$head" ] || fail "head $out is not the reviewed $head"
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
  local below status
  below=$(gh api "repos/{owner}/{repo}/pulls/$pr" --jq '.stack // empty
    | "\(.id) \(.position)"' 2>&1) || fail "could not be read" "$below"
  if [ -n "$below" ]; then
    below=$(gh api "repos/{owner}/{repo}/pulls?state=open&per_page=100" --jq "[.[]
      | select(.stack.id == ${below% *} and .stack.position < ${below#* }) | \"#\(.number)\"]
      | join(\" \")" 2>&1) || fail "could not be read" "$below"
    [ -z "$below" ] || fail "has open PRs below it in its stack: $below"
  fi

  out=$(gh api -X PUT "repos/{owner}/{repo}/pulls/$pr/merge-async" -f sha="$head" \
    -f merge_method=squash -f merge_action=direct_merge 2>&1) || fail "merge refused" "$out"
  while status=$(jq -r .status <<<"$out" 2>/dev/null) && [ "$status" = pending ]; do
    sleep "$poll"
    out=$(gh api "repos/{owner}/{repo}/pulls/$pr/merge-async/$(jq -r .details.uuid <<<"$out")" 2>&1) ||
      fail "merge status could not be read" "$out"
  done
  [ "$status" = merged ] || fail "merge refused" "$out"
  merged=$(jq -r .details.sha <<<"$out")
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

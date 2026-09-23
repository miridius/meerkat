#!/usr/bin/env bash
# Pre-push hook: refuse to push private references to this public repo.
#
# Everything pushed here is world-visible and effectively permanent: a
# squashed branch still leaves the commits a merged PR references, and
# editing a PR body leaves the old text in GitHub's edit history. So the
# only place to catch a private reference is before it leaves the
# machine.
#
# Two classes, both of which have reached origin before:
#
#   - Claude Code session URLs, injected into commit trailers and PR
#     descriptions by the harness unless `attribution.sessionUrl` is
#     false. They identify a private transcript.
#   - Internal ticket IDs and company identifiers, usually copied in
#     from a real review being used as test data.
#
# Checks the commits being pushed AND the tree at their tips, since a
# leak can sit in either. Bypass a false positive with
# `git push --no-verify`.
#
# `scripts/no-private-refs.sh --self-test` checks every pattern against
# a string it must match and one it must not. Run it after editing a
# pattern: the two scans use different regex engines (BSD grep for
# commit messages, git's own for tracked files) and `\b` works in only
# one of them, so a pattern can pass on one side and silently match
# nothing on the other.

set -euo pipefail

# Each entry is "<label>|<extended regex>|<must match>|<must not match>".
#
# Boundaries are spelled out as character classes rather than `\b`,
# which git grep's ERE does not support. Keep them anchored enough to
# avoid ordinary prose: a bare fragment of a name would fire on
# almost anything.
#
# The private names below are assembled from split literals: this file
# is itself tracked and scanned, so a contiguous private reference
# here would leak it into the public repo and make the hook refuse
# every push — including the push that would fix it.
org_ref='griffin''bank'
repo_ref='banks''y'
mail_dom='grif''fin'
ticket_ref='t''ool-9999'
PATTERNS=(
  "Claude Code session URL|claude\.ai/code/session|see https://claude.ai/code/"'session_01AB'"|see claude.ai/code/artifact/1"
  "internal ticket ID|(^|[^A-Za-z0-9_-])[Tt][Oo][Oo][Ll]-[0-9]{3,5}|branch x/${ticket_ref}-queue|the tooling-12 helper"
  "internal repo or org name|(^|[^A-Za-z0-9_-])(${org_ref}|${repo_ref})([^A-Za-z0-9_-]|$)|repos/${org_ref}/${repo_ref}|${repo_ref}esque street art"
  "local absolute path|/Users/[A-Za-z0-9_-]|~/\.claude/[A-Za-z0-9_-]|ran /Users/"'a'"/oss/meerkat|paths (\`/Users/…\`)"
  "work email address|[A-Za-z0-9._%+-]+@${mail_dom}\.(com|sh)|mail a.dev@${mail_dom}.com now|mail someone@example.com now"
)

entry_field() { printf '%s' "$1" | cut -d'|' -f"$2"; }

# The patterns hold a `|` of their own, so the fields around them are
# taken from the ends rather than by splitting on every separator.
pattern_of() {
  local entry="$1" rest
  rest="${entry#*|}"
  rest="${rest%|*}"
  printf '%s' "${rest%|*}"
}

# git grep reads files, never stdin, so each sample goes through a
# temporary file to reach git's own regex engine.
git_grep_matches() {
  local pattern="$1" sample="$2" dir
  dir=$(mktemp -d)
  printf '%s\n' "$sample" > "$dir/sample.txt"
  # From inside a repo, --no-index still refuses a pathspec outside it,
  # so the check runs with the sample's own directory as the cwd.
  local rc=0
  (cd "$dir" && git grep --no-index -qE "$pattern" -- sample.txt) > /dev/null 2>&1 || rc=$?
  rm -rf "$dir"
  return "$rc"
}

grep_matches() {
  printf '%s\n' "$2" | grep -qE "$1" > /dev/null 2>&1
}

self_test() {
  local failed=0
  for entry in "${PATTERNS[@]}"; do
    local label pattern positive negative
    label=$(entry_field "$entry" 1)
    pattern=$(pattern_of "$entry")
    positive="${entry%|*}"
    positive="${positive##*|}"
    negative="${entry##*|}"

    for engine in grep_matches git_grep_matches; do
      if ! "$engine" "$pattern" "$positive"; then
        echo "SELF-TEST: '$label' misses its own example under $engine: $positive" >&2
        failed=1
      fi
      if "$engine" "$pattern" "$negative"; then
        echo "SELF-TEST: '$label' fires on its counter-example under $engine: $negative" >&2
        failed=1
      fi
    done
  done

  if [ "$failed" -eq 0 ]; then
    echo "no-private-refs: ${#PATTERNS[@]} patterns pass on both regex engines."
  fi
  return "$failed"
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit $?
fi

# A pattern that matches nothing lets every push through while looking
# like a check, so the patterns are proved before they are trusted.
if ! self_test > /dev/null; then
  self_test || true
  echo "no-private-refs: a pattern is broken — refusing the push." >&2
  exit 1
fi

# `git push` feeds the hook "<local ref> <local sha> <remote ref>
# <remote sha>" per ref on stdin. lefthook does not forward that, so
# work out the range from the upstream instead, and fall back to
# origin/main for a branch that has none yet.
upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || echo "")
if [ -n "$upstream" ]; then
  base="$upstream"
else
  base="origin/main"
fi

if ! git rev-parse --verify --quiet "$base" > /dev/null; then
  echo "no-private-refs: cannot resolve '$base' — refusing the push." >&2
  exit 1
fi

found=0

for entry in "${PATTERNS[@]}"; do
  label=$(entry_field "$entry" 1)
  pattern=$(pattern_of "$entry")

  if messages=$(git log --format='%H %s%n%b' "$base..HEAD" 2>/dev/null) &&
    hits=$(printf '%s\n' "$messages" | grep -nE "$pattern" || true) &&
    [ -n "$hits" ]; then
    echo "ERROR: $label in a commit message being pushed:" >&2
    printf '%s\n' "$hits" | sed 's/^/    /' >&2
    found=1
  fi

  # Tracked files at HEAD. `git grep` skips the working tree's
  # untracked and ignored files, which are not being pushed.
  if hits=$(git grep -nE "$pattern" HEAD -- . 2>/dev/null || true) &&
    [ -n "$hits" ]; then
    echo "ERROR: $label in a tracked file:" >&2
    printf '%s\n' "$hits" | sed 's/^/    /' >&2
    found=1
  fi
done

if [ "$found" -eq 0 ]; then
  exit 0
fi

echo "" >&2
echo "This repo is public. Rewrite the commit or the file and push again." >&2
echo "If the match is a false positive, bypass with: git push --no-verify" >&2
echo "and widen the pattern in scripts/no-private-refs.sh." >&2
exit 1

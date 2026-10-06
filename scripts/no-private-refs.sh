#!/usr/bin/env bash
# Pre-push hook: refuse to push private references to this public repo.
#
# Everything pushed here is world-visible and effectively permanent: a
# squashed branch still leaves the commits a merged PR references, and
# editing a PR body leaves the old text in GitHub's edit history. So the
# only place to catch a private reference is before it leaves the
# machine.
#
# Two sets of patterns:
#
#   - Generic ones, defined below: Claude Code session URLs (injected
#     into commit trailers and PR descriptions by the harness unless
#     `attribution.sessionUrl` is false), local absolute paths, and
#     email addresses.
#   - Private ones, read from `info/private-refs` in the git common dir
#     (`.git/info/private-refs` in a plain clone). That file is never
#     tracked, so it holds names that would themselves leak if written
#     here. One extended regex per line; blank lines and lines starting
#     with `#` are skipped. Without the file the push and `--self-test`
#     are refused; create it empty if there is nothing private to guard.
#
# Checks everything the push publishes: the commits (headers, messages,
# and the lines and paths they add), annotated tags, the
# names of the refs pushed to, and the tree at each tip. A false
# positive is fixed by narrowing the pattern that matched or, for an
# address that is public by design, adding it to ALLOWED.
#
# Every scan uses git grep's extended regexes, which read escapes like
# `\b` and `\d` as plain letters. `scripts/no-private-refs.sh
# --self-test` checks every generic pattern against a string it must
# match and one it must not, and every private pattern for errors and
# for some text that would make it silently miss what it is meant to
# match.
# Run it after editing a pattern.

set -euo pipefail

# Pushed content need not be valid text, so every tool here reads bytes:
# BSD sed stops on bytes that are not valid UTF-8. Each git grep runs
# once more in a UTF-8 locale, though: under C, `.` and bracket
# expressions see a multibyte character's bytes one at a time, while
# under UTF-8 they can fail to match on a line with invalid bytes. So the
# UTF-8 pass over what the push publishes reads a copy with those bytes
# dropped, and the hits of both passes are reported. The UTF-8 pass over
# each tip's tree reads it as it is: every line there is either already
# public or added by a pushed commit, whose copy is read.
export LC_ALL=C
UTF8_LOCALE=$(locale -a 2> /dev/null | grep -m1 -ixE '(c|en_us)\.utf-?8' || true)
if [ -z "$UTF8_LOCALE" ]; then
  echo "no-private-refs: no UTF-8 locale to search in — refusing the push." >&2
  exit 1
fi

# Commands here read what the push sends. Replace refs would show them
# a different object from the one pack-objects sends.
export GIT_NO_REPLACE_OBJECTS=1

# Each entry is "<label>|<extended regex>|<must match>|<must not match>".
#
# git grep's ERE has no `\b`, so a pattern here or in the private file
# that needs a word boundary spells it out as a character class. Keep
# private patterns anchored enough to avoid ordinary prose: a bare
# fragment of a name would fire on almost anything.
#
# This file is itself tracked and scanned, so the examples are split
# where a contiguous one would match its own pattern.
#
# Each domain label of an email address starts with a letter or digit,
# as a hostname's must, so stray bytes in a binary file such as
# `r@-2.kt` are not read as one.
PATTERNS=(
  "Claude Code session URL|claude\.ai/code/session|see https://claude.ai/code/"'session_01AB'"|see claude.ai/code/artifact/1"
  "local absolute path|/Users/[A-Za-z0-9_-]|~/\.claude/[A-Za-z0-9_-]|ran /Users/"'a'"/oss/meerkat|paths (\`/Users/…\`)"
  "email address|[A-Za-z0-9._%+-]+@[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)*\.[A-Za-z]{2,}|mail a.dev@"'corp.io'" now|mail someone@example.com now"
)

# Generic-pattern matches that are public by design, in any case:
# placeholder domains and the no-reply addresses of commit trailers and
# GitHub's own commits. Applied to each match on its own, after the `:`
# that precedes it in git grep's `-o` output. Private patterns never go
# through it, so a private match is reported even when it ends in one
# of these addresses.
ALLOWED=':([a-z0-9._%+-]+@example\.(com|org|net)|noreply@anthropic\.com|noreply@github\.com|[a-z0-9._%+-]+@users\.noreply\.github\.com)$'

# grep exits 1 when it keeps nothing, which is not a failure here.
drop_allowed() { grep -aviE "$ALLOWED" || [ "$?" -eq 1 ]; }

entry_field() { printf '%s' "$1" | cut -d'|' -f"$2"; }

# The patterns hold a `|` of their own, so the fields around them are
# taken from the ends rather than by splitting on every separator.
pattern_of() {
  local entry="$1" rest
  rest="${entry#*|}"
  rest="${rest%|*}"
  printf '%s' "${rest%|*}"
}

# Runs `git <args>`, a git grep with `-o`, in the given locale and
# prints its hits. Returns git grep's status, or 3 when it matched but
# printed nothing: `-o` prints no empty match and skips the rest of its
# line, so the matches of a pattern that can match empty text are lost.
grep_in() {
  local locale="$1" out rc=0
  shift
  out=$(LC_ALL=$locale git -c color.grep=never "$@") || rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    return 3
  fi
  printf '%s' "$out"
  return "$rc"
}

# Combines a C pass and a UTF-8 pass, given as `<status> <hits>` twice.
# Prints the hits of either, and returns 1 when neither matches, 2 when
# either fails, and 3 when either matched empty text.
combine() {
  local rc_c="$1" out_c="$2" rc_u="$3" out_u="$4"
  if [ "$rc_c" -eq 2 ] || [ "$rc_u" -eq 2 ] || [ "$rc_c" -gt 3 ] || [ "$rc_u" -gt 3 ]; then
    return 2
  fi
  if [ "$rc_c" -eq 3 ] || [ "$rc_u" -eq 3 ]; then
    return 3
  fi
  [ "$rc_c" -eq 0 ] || [ "$rc_u" -eq 0 ] || return 1
  printf '%s\n%s\n' "$out_c" "$out_u" | sed '/^$/d' | sort -u
}

# Searches the whole trees of the pushed tips, from whatever directory
# the script runs in; `git grep <tips>` never reads the working tree.
grep_tips() {
  local out_c out_u rc_c=0 rc_u=0
  out_c=$(grep_in C grep --text -noE -e "$1" "${tips[@]}" -- :/) || rc_c=$?
  out_u=$(grep_in "$UTF8_LOCALE" grep --text -noE -e "$1" "${tips[@]}" -- :/) || rc_u=$?
  combine "$rc_c" "$out_c" "$rc_u" "$out_u"
}

# Searches the files of a directory, which need not be in a repo, and
# for the UTF-8 pass those of the optional third argument, a copy of it
# with invalid bytes dropped. Prints `<file>:<line>:<match>` for each
# match and returns combine's status. From inside a repo, --no-index
# still refuses a pathspec outside it, so git starts in the directory.
grep_dir() {
  local out_c out_u rc_c=0 rc_u=0
  out_c=$(grep_in C -C "$1" grep --no-index --text -noE -e "$2" -- .) || rc_c=$?
  out_u=$(grep_in "$UTF8_LOCALE" -C "${3:-$1}" grep --no-index --text -noE -e "$2" -- .) || rc_u=$?
  combine "$rc_c" "$out_c" "$rc_u" "$out_u"
}

# git grep reads files, never stdin, so each sample goes through a
# temporary file.
grep_sample() {
  local pattern="$1" sample="$2" dir rc=0
  dir=$(mktemp -d)
  printf '%s\n' "$sample" > "$dir/sample.txt"
  grep_dir "$dir" "$pattern" || rc=$?
  rm -rf "$dir"
  return "$rc"
}

# True when the sample holds a generic match the scan would report.
reports() {
  local out
  out=$(grep_sample "$1" "$2" 2> /dev/null || true)
  [ -n "$(printf '%s\n' "$out" | drop_allowed)" ]
}

# Prints git grep's error for an invalid pattern, prefixed by where the
# pattern lives, and fails if there was one. A pattern that matches an
# empty line fails too; one that matches empty text only beside other
# text refuses the push when the scan meets it.
valid_regex() {
  local where="$1" pattern="$2" rc=0 err
  err=$(grep_sample "$pattern" "" 2>&1 > /dev/null) || rc=$?
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]; then
    echo "SELF-TEST: $where matches empty text, so git grep cannot show its matches" >&2
    return 1
  fi
  if [ "$rc" -gt 1 ]; then
    echo "SELF-TEST: $where is not a valid regex: $err" >&2
    return 1
  fi
}

PRIVATE_FILE="$(git rev-parse --git-common-dir)/info/private-refs"

if [ ! -f "$PRIVATE_FILE" ] || [ ! -r "$PRIVATE_FILE" ]; then
  echo "no-private-refs: $PRIVATE_FILE is missing or not a readable file — refusing the push." >&2
  echo "It lists this machine's private patterns, one extended regex per line." >&2
  echo "Create it, empty if there is nothing private to guard, and push again." >&2
  exit 1
fi

# Each pattern with the line of the file it came from. A CRLF line
# ending and a UTF-8 byte-order mark are dropped: kept, they would be
# part of the pattern.
PRIVATE=()
PRIVATE_LINES=()
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  line=${line%$'\r'}
  [ "$lineno" -gt 1 ] || line=${line#$'\xef\xbb\xbf'}
  case "$line" in '' | '#'*) continue ;; esac
  PRIVATE+=("$line")
  PRIVATE_LINES+=("$lineno")
done < "$PRIVATE_FILE"

self_test() {
  local failed=0
  for entry in "${PATTERNS[@]}"; do
    local label pattern positive negative
    label=$(entry_field "$entry" 1)
    pattern=$(pattern_of "$entry")
    positive="${entry%|*}"
    positive="${positive##*|}"
    negative="${entry##*|}"

    if ! valid_regex "'$label'" "$pattern"; then
      failed=1
      continue
    fi
    if ! reports "$pattern" "$positive"; then
      echo "SELF-TEST: '$label' misses its own example: $positive" >&2
      failed=1
    fi
    if reports "$pattern" "$negative"; then
      echo "SELF-TEST: '$label' fires on its counter-example: $negative" >&2
      failed=1
    fi
  done

  # Private patterns have no examples, so they are checked only for
  # what would break them: an invalid regex, one that matches an empty
  # line, or text that makes one silently miss what it is meant to
  # match. An escaped backslash is a literal one, so it is no escape
  # here.
  local i
  for ((i = 0; i < ${#PRIVATE[@]}; i++)); do
    local pattern="${PRIVATE[$i]}" where="line ${PRIVATE_LINES[$i]} of $PRIVATE_FILE"
    case "${pattern//'\\'/}" in
      *'\'[A-Za-z0-9'<>']*)
        echo "SELF-TEST: $where has a backslash escape such as \\b, \\d, \\s or \\<, which git grep's ERE reads as a plain character; use a bracket class such as [0-9] or [[:space:]]" >&2
        failed=1
        continue
        ;;
      *[[:cntrl:]]*)
        echo "SELF-TEST: $where contains a control character, such as a tab or carriage return" >&2
        failed=1
        continue
        ;;
      [[:space:]]* | *[[:space:]])
        echo "SELF-TEST: $where starts or ends with whitespace; write [ ] where a space is meant" >&2
        failed=1
        continue
        ;;
    esac
    valid_regex "$where" "$pattern" || failed=1
  done

  if [ "$failed" -eq 0 ]; then
    echo "no-private-refs: ${#PATTERNS[@]} generic and ${#PRIVATE[@]} private patterns pass."
  fi
  return "$failed"
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit $?
fi

# A pattern that matches nothing lets every push through while looking
# like a check, so the patterns are proved before they are trusted.
if ! self_test > /dev/null 2>&1; then
  self_test || true
  echo "no-private-refs: a pattern is broken — refusing the push." >&2
  exit 1
fi

# .lefthook/pre-push/pre-push.sh passes `--remote <url>` and, for each
# ref being pushed, `--ref <remote ref name>` and its local tip. Run by
# hand with no tips, it checks HEAD. The commits checked are the ones
# not reachable from any remote ref this clone also has, since this
# push is what publishes them; run by hand with no remote, the ones no
# remote-tracking branch has.
remote=""
ref_names=()
tips=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --remote)
      remote="$2"
      shift 2
      if [ -z "$remote" ]; then
        echo "no-private-refs: no remote to ask what it already has — refusing the push." >&2
        exit 1
      fi
      ;;
    --ref) ref_names+=("$2"); shift 2 ;;
    *) tips+=("$1"); shift ;;
  esac
done
[ "${#tips[@]}" -gt 0 ] || tips=(HEAD)

# What the push publishes besides its tips' trees, one file per object
# so a hit names it: each raw commit object, with all its headers and
# its message, the lines and paths each commit adds, each annotated
# tag, and the ref names. Binary files are diffed as text, so their
# added content is read too.
texts=$(mktemp -d)
trap 'rm -rf "$texts"' EXIT

# What the remote has is asked of the remote itself: tracking branches
# can be stale, and a new remote or a URL has none. Any of its objects
# this clone lacks cannot be in the push, so only the ones it has are
# excluded. A remote that cannot be asked refuses the push rather than
# letting a guess decide which commits count as public.
remote_ahead=""
if [ -n "$remote" ]; then
  if ! git ls-remote "$remote" > "$texts/remote-refs" ||
    ! cut -f1 "$texts/remote-refs" | GIT_NO_LAZY_FETCH=1 git cat-file --batch-check > "$texts/remote-objects"; then
    # The URL is not echoed, since it can hold credentials.
    echo "no-private-refs: cannot ask the remote what it already has — refusing the push." >&2
    exit 1
  fi
  # `--batch-check` prints `<sha> missing` for an object this clone lacks,
  # and GIT_NO_LAZY_FETCH stops a partial clone fetching each one.
  sed -n -e '/ missing$/d' -e 's/^\([0-9a-f]*\) .*/^\1/p' "$texts/remote-objects" > "$texts/published"
  # A remote branch or tag tip this clone lacks hides what is below it,
  # so history the remote already holds can be scanned as new until a
  # fetch. Other refs, such as a host's pull-request refs, are not
  # fetched, so a fetch would not help. `--batch-check` keeps the order
  # of its input. grep reads all its input: with -q it would stop at the
  # first match, and a paste still writing would die of SIGPIPE, failing
  # the pipeline under pipefail and losing the fetch hint.
  if paste -d' ' "$texts/remote-objects" <(cut -f2 "$texts/remote-refs") |
    grep -E ' missing refs/(heads|tags)/' > /dev/null; then
    remote_ahead=1
  fi
  rm "$texts/remote-refs" "$texts/remote-objects"
  list_commits() { git rev-list --stdin "${tips[@]}" < "$texts/published"; }
else
  list_commits() { git rev-list "${tips[@]}" --not --remotes; }
fi
if ! commits=$(list_commits); then
  echo "no-private-refs: cannot list the commits being pushed — refusing the push." >&2
  exit 1
fi
rm -f "$texts/published"
for sha in $commits; do
  if ! git cat-file commit "$sha" > "$texts/commit-$sha" ||
    ! git -c core.quotePath=false diff-tree --cc --text --no-textconv --no-ext-diff -r --root --no-color --no-commit-id "$sha" > "$texts/raw" ||
    ! git diff-tree --cc -r --root --name-only -z --diff-filter=ACR --no-commit-id "$sha" > "$texts/raw-paths"; then
    echo "no-private-refs: cannot read commit $sha — refusing the push." >&2
    exit 1
  fi
  # Only the lines and paths a commit adds: anything a parent has is
  # already public or checked as part of that parent. Each diff line
  # starts with one marker column per parent, one for a root commit, and
  # a line no parent has is `+` in every column. The markers are
  # stripped so they are not read as part of a match. Each file's header
  # runs from its `diff` line to its first hunk.
  # rev-list, like diff-tree, sees a commit at a shallow boundary as a
  # root, which its raw `parent` headers would not.
  parents=$(($(git rev-list --parents -n 1 "$sha" | wc -w) - 1))
  [ "$parents" -gt 0 ] || parents=1
  if ! sed -nE -e '/^diff /,/^@@/d' -e "s/^\+{$parents}//p" "$texts/raw" > "$texts/diff-$sha" ||
    ! tr '\0' '\n' < "$texts/raw-paths" > "$texts/paths-$sha"; then
    echo "no-private-refs: cannot read commit $sha — refusing the push." >&2
    exit 1
  fi
  # `--cc` prints only "Binary files differ" for a binary file, even with
  # `--text`, so each binary file a merge changes is read whole.
  if [ "$parents" -gt 1 ]; then
    path=""
    while IFS= read -r line; do
      case "$line" in
        'diff --cc '*) path=${line#diff --cc } ;;
        *)
          # Git quotes a path that has special characters.
          if [ "${path#\"}" != "$path" ]; then
            echo "no-private-refs: cannot read binary file $path in merge $sha — refusing the push." >&2
            exit 1
          fi
          # A file the merge deletes adds nothing. A newline after each
          # file keeps two files' bytes from joining into one match.
          if git cat-file -e "$sha:$path" 2> /dev/null; then
            if ! git cat-file blob "$sha:$path" >> "$texts/diff-$sha"; then
              echo "no-private-refs: cannot read $path in merge $sha — refusing the push." >&2
              exit 1
            fi
            echo >> "$texts/diff-$sha"
          fi
          ;;
      esac
    done < <(grep -a -e '^diff --cc ' -e '^Binary files' "$texts/raw")
  fi
  rm "$texts/raw" "$texts/raw-paths"
done
for tip in "${tips[@]}"; do
  object=$tip
  while :; do
    if ! type=$(git cat-file -t "$object"); then
      echo "no-private-refs: cannot read object $object — refusing the push." >&2
      exit 1
    fi
    [ "$type" = tag ] || break
    sha=$(git rev-parse "$object")
    if ! git cat-file tag "$sha" > "$texts/tag-$sha"; then
      echo "no-private-refs: cannot read tag $sha — refusing the push." >&2
      exit 1
    fi
    # A tag's first line names the object it tags, which may be a tag.
    object=$(sed -n '1s/^object //p' "$texts/tag-$sha")
  done
done
# Each ref name both in full and without its `refs/<kind>/` prefix, so
# a pattern anchored at the start can match the short name.
for ref in ${ref_names[@]+"${ref_names[@]}"}; do
  printf '%s\n%s\n' "$ref" "${ref#refs/*/}" >> "$texts/ref-names"
done

# The UTF-8 pass's copy. iconv's status cannot tell a failure from a
# dropped byte: some implementations exit 1 after -c drops one, while
# macOS's exits 0 then but 1 when a write fails. So each copy is made
# with five more newlines at its end, and its lines are counted: a copy
# cut short anywhere lacks some. Five, because when fewer bytes follow a
# character's first byte than it needs, at the end of its input, macOS's
# iconv drops them all, newlines included, and that is at most four;
# anywhere else -c keeps every newline. The extra newlines add only empty lines, which match no
# pattern, since the self-test refuses one that matches an empty line.
pad=$'\n\n\n\n\n'
utf8=$(mktemp -d)
trap 'rm -rf "$texts" "$utf8"' EXIT
for file in "$texts"/*; do
  [ -e "$file" ] || continue
  rc=0
  { cat "$file" && printf '%s' "$pad"; } | iconv -c -f UTF-8 -t UTF-8 > "$utf8/${file##*/}" || rc=$?
  if [ "$rc" -gt 1 ] ||
    ! lines=$(wc -l < "$file") ||
    ! copied=$(wc -l < "$utf8/${file##*/}") ||
    [ "$copied" -ne $((lines + ${#pad})) ]; then
    echo "no-private-refs: cannot convert ${file##*/} — refusing the push." >&2
    exit 1
  fi
done

found=0
history_hit=""

# Refuses the push when a search fails, given its status, the pattern's
# label and what it searched.
check_search() {
  case "$1" in
    0 | 1) ;;
    3)
      echo "no-private-refs: $2 matches empty text in $3, so git grep cannot show its matches — refusing the push." >&2
      exit 1
      ;;
    *)
      echo "no-private-refs: cannot search $3 — refusing the push." >&2
      exit 1
      ;;
  esac
}

scan() {
  local label="$1" pattern="$2" generic="$3" hits rc

  rc=0
  hits=$(grep_dir "$texts" "$pattern" "$utf8") || rc=$?
  check_search "$rc" "$label" "the commits, tags and ref names being pushed"
  [ -z "$generic" ] || hits=$(printf '%s\n' "$hits" | drop_allowed)
  if [ -n "$hits" ]; then
    echo "ERROR: $label in a commit, tag or ref name being pushed:" >&2
    printf '%s\n' "$hits" | sed 's/^/    /' >&2
    found=1
    # Not -q, for the reason given above `remote_ahead=1`: printf would
    # die the same way, losing the fetch hint.
    ! printf '%s\n' "$hits" | grep '^\(commit\|diff\|paths\)-' > /dev/null || history_hit=1
  fi

  rc=0
  hits=$(grep_tips "$pattern") || rc=$?
  check_search "$rc" "$label" "the files being pushed"
  [ -z "$generic" ] || hits=$(printf '%s\n' "$hits" | drop_allowed)
  if [ -n "$hits" ]; then
    echo "ERROR: $label in a tracked file:" >&2
    printf '%s\n' "$hits" | sed 's/^/    /' >&2
    found=1
  fi
}

for entry in "${PATTERNS[@]}"; do
  scan "$(entry_field "$entry" 1)" "$(pattern_of "$entry")" generic
done

for ((i = 0; i < ${#PRIVATE[@]}; i++)); do
  scan "private pattern on line ${PRIVATE_LINES[$i]} of $PRIVATE_FILE" "${PRIVATE[$i]}" ""
done

if [ "$found" -eq 0 ]; then
  exit 0
fi

echo "" >&2
if [ -n "$remote_ahead" ] && [ -n "$history_hit" ]; then
  echo "The remote has commits this clone lacks, so a match may be in history" >&2
  echo "it already holds. Run \`git fetch\` and push again first." >&2
fi
echo "This repo is public. Rewrite what matched and push again." >&2
echo "If the match is a false positive, narrow the pattern in" >&2
echo "scripts/no-private-refs.sh or $PRIVATE_FILE and push again;" >&2
echo "for a generic email address that is public by design, add it" >&2
echo "to ALLOWED instead." >&2
exit 1

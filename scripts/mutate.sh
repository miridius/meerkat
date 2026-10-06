#!/usr/bin/env bash
# Mutation testing for meerkat.
#
# Runs `mix muex` against the meerkat Elixir code. muex rewrites
# operators / literals one at a time and re-runs the tests that
# cover each rewrite. A rewrite those tests still pass against
# is an uncovered behaviour — fix the test or the code.
#
# Modes:
#   scripts/mutate.sh             — mutate every line of every
#                                   lib/meerkat/*.ex (skips application
#                                   — supervisor plumbing). Slow.
#   scripts/mutate.sh changed     — mutate only the lib/**/*.ex lines
#                                   changed vs the merge base with
#                                   origin/main (override with
#                                   BASE_BRANCH), uncommitted edits
#                                   included (muex --since).
#   scripts/mutate.sh staged      — mutate only the lib/**/*.ex lines
#                                   staged for the next commit (muex
#                                   --staged). The lefthook pre-commit
#                                   hook runs this mode.
#   scripts/mutate.sh <path…>     — mutate every line of the named
#                                   files.
#
# Every mode fails when any mutant survives or no test reaches it.
#
# Pass extra muex flags through after `--`:
#   scripts/mutate.sh changed -- --concurrency 4

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -d lib/meerkat ]]; then
  echo "scripts/mutate.sh: lib/meerkat not found at $PWD — run from the meerkat repo." >&2
  exit 2
fi

# Files muex's operator rewrites would just churn through without
# real signal. Supervisor plumbing.
SKIP_PATTERNS=(
  'lib/meerkat/application.ex'
)

skip_file() {
  local path=$1
  for skip in "${SKIP_PATTERNS[@]}"; do
    [[ "$path" == "$skip" ]] && return 0
  done
  return 1
}

# Collects the files under $1 matching find's -name $2 (to the depth in
# $3, if given) into `files`, minus SKIP_PATTERNS. Captured into a
# tempfile + exit status checked — process-subst `< <(find …)` would
# swallow a find failure (set -e doesn't propagate through it).
collect_files() {
  local dir=$1 name=$2 depth=${3:-}
  local listing
  listing=$(mktemp)
  if ! find "$dir" ${depth:+-maxdepth "$depth"} -name "$name" -type f | sort > "$listing"; then
    rm -f "$listing"
    echo "scripts/mutate.sh: find under $dir failed." >&2
    exit 2
  fi
  while IFS= read -r f; do
    skip_file "$f" || files+=("$f")
  done < "$listing"
  rm -f "$listing"
}

# Whether `git diff <args>` adds or changes any lib/**/*.ex line, the
# only lines muex's --since / --staged can mutate. The diff is captured
# first: piped straight into `grep -q`, git could die of SIGPIPE and
# pipefail would read a match as a failure. An external diff tool or
# textconv filter would print no `+` lines and skip the gate.
has_added_lines() {
  local diff
  if ! diff=$(git diff --no-ext-diff --no-textconv --unified=0 --no-color --diff-filter=d "$@" -- ':(glob)lib/**/*.ex'); then
    echo "scripts/mutate.sh: git diff $* failed." >&2
    exit 2
  fi
  awk '/^\+/ && !/^\+\+\+ / { found = 1 } END { exit !found }' <<<"$diff"
}

# Scopes muex to the lines its diff flags ($@) select. Every such line
# counts, so --no-filter keeps muex from skipping a file it rates too
# simple to be worth mutating, and --no-optimize from dropping the
# mutants of a function it rates too simple.
line_scope() {
  scope_args=("$@" --no-filter --no-optimize)
}

mode=${1:-default}
shift || true
# `scripts/mutate.sh -- <muex flags>` is the default mode with flags.
if [[ "$mode" == "--" ]]; then
  mode=default
  set -- -- "$@"
fi

files=()
scope_args=()
muex_env=()
case "$mode" in
  default)
    collect_files lib/meerkat '*.ex' 1
    ;;
  changed)
    base="${BASE_BRANCH:-origin/main}"
    if ! git rev-parse --verify "$base" >/dev/null 2>&1; then
      echo "scripts/mutate.sh: base ref '$base' not found; fetch origin first." >&2
      exit 2
    fi
    if ! has_added_lines --merge-base "$base"; then
      echo "scripts/mutate.sh: no lib/**/*.ex lines changed vs $base — nothing to mutate."
      exit 0
    fi
    collect_files lib '*.ex'
    line_scope --since "$base"
    ;;
  staged)
    # During `git commit -a` or `git commit <paths>`, GIT_INDEX_FILE names
    # a temporary index holding the commit's contents. --git-path resolves
    # it (or the usual index) to an absolute path, which muex --staged
    # reads after the rest of git's hook environment is cleared below.
    index=$(git rev-parse --path-format=absolute --git-path index)
    if ! has_added_lines --cached; then
      echo "scripts/mutate.sh: no lib/**/*.ex lines staged — nothing to mutate."
      exit 0
    fi
    collect_files lib '*.ex'
    line_scope --staged
    muex_env=(GIT_INDEX_FILE="$index")
    ;;
  *)
    # Treat every arg up to `--` as a file path. Flag-shaped args
    # (start with `-`) here are almost always a forgotten `--`;
    # reject loudly rather than pass them to muex as bogus paths.
    if [[ "$mode" == -* ]]; then
      echo "scripts/mutate.sh: '$mode' looks like a flag. Did you forget '--'?" >&2
      echo "Usage: scripts/mutate.sh <path…> [-- <muex flags>]" >&2
      exit 2
    fi
    files=("$mode")
    while [[ $# -gt 0 && "$1" != "--" ]]; do
      if [[ "$1" == -* ]]; then
        echo "scripts/mutate.sh: '$1' looks like a flag. Did you forget '--'?" >&2
        exit 2
      fi
      files+=("$1")
      shift
    done
    ;;
esac

if [[ ${#files[@]} -eq 0 ]]; then
  echo "scripts/mutate.sh: no files selected — nothing to mutate." >&2
  exit 2
fi

# Pass-through extra flags after `--`.
extra_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --) shift; extra_args+=("$@"); break ;;
    *)  extra_args+=("$1"); shift ;;
  esac
done
# The run is judged from the JSON report the gate below asks for; muex
# keeps the last of a repeated flag, so a later one would move or
# replace the report, or exit before it is judged.
for arg in "${extra_args[@]}"; do
  case "$arg" in
    --format | --format=* | --output | --output=* | --fail-at | --fail-at=*)
      echo "scripts/mutate.sh: $arg is set by this script; drop it." >&2
      exit 2
      ;;
  esac
done

# Git exports GIT_DIR, GIT_INDEX_FILE and friends to hooks; left set,
# they would point Mix's checkout of git dependencies, and every test's
# fixture repo, at this repository.
# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars)

if [[ ${#scope_args[@]} -eq 0 ]]; then
  echo "scripts/mutate.sh: mutating ${#files[@]} file(s):"
  printf '  %s\n' "${files[@]}"
else
  echo "scripts/mutate.sh: mutating the $mode lines of lib/**/*.ex."
fi

MIX_ENV=test mix deps.get
# The suite needs node_modules, which a fresh worktree lacks.
pnpm install --frozen-lockfile --ignore-scripts --prefer-offline
MIX_ENV=test mix compile --warnings-as-errors

# muex's `--files` accepts comma-separated globs/paths.
joined=$(IFS=,; echo "${files[*]}")
# --coverage-guided runs each mutant against the test files that execute
# its line, and skips mutants on lines no test executes (reported as
# no coverage). For lines `:cover` has no data for, it falls back to
# muex's dependency analysis, then to the full suite. muex runs as many
# test BEAMs at once as there are cores; like scripts/mix-test.sh, cap
# them at half (at least one) so a commit leaves the machine usable. A
# --concurrency after `--` overrides this.
jobs=$(($(getconf _NPROCESSORS_ONLN) / 2))
((jobs >= 1)) || jobs=1
muex=(mix muex --files "$joined" --coverage-guided --concurrency "$jobs" "${scope_args[@]}")

# Every mode judges the run from muex's JSON report rather than its
# score: muex's default --fail-at passes a run with survivors, its
# score ignores no-coverage mutants, and lines that yield no mutants
# have nothing to score, and must pass. muex prints the report's path,
# so the report is kept, in _build/, until the next run replaces it.
# muex strips GIT_INDEX_FILE from the test runs it starts.
mkdir -p _build
report="$PWD/_build/mutate.json"
# muex writes no report when there is nothing to mutate, as for staged
# comments or lib/meerkat/application.ex alone, so an earlier run's
# report must not be left for this run to judge.
rm -f "$report"
env "${muex_env[@]}" "${muex[@]}" --fail-at 0 \
  --format json --output "$report" "${extra_args[@]}"

if [[ ! -f "$report" ]]; then
  echo "scripts/mutate.sh: the selected lib/ lines produce no mutants."
  exit 0
fi

# Only the statuses below are judged; one muex adds later would
# otherwise pass unseen.
unknown=$(jq -r '[.mutations[].status]
  - ["killed", "survived", "no_coverage", "timeout", "invalid", "equivalent", "ignored"]
  | unique | join(", ")' "$report")
if [[ -n "$unknown" ]]; then
  echo "scripts/mutate.sh: muex reported unknown mutant status(es): $unknown." >&2
  exit 2
fi

# A survivor is a line whose behaviour the tests do not pin
# down. A no-coverage mutant is the same gap, found without running:
# no ExUnit test executes its line.
# muex's patch holds the whole enclosing expression, which for a deleted
# statement is the whole module body, so print only the lines one side
# has and the other lacks, at most six per side.
failing=$(jq -r '
  def only($sign; $lines; $other):
    ($lines - $other) as $diff
    | $diff[:6] | map("\n    \($sign) " + .) | join("")
      + (if ($diff | length) > 6 then "\n    \($sign) …" else "" end);
  .mutations[]
  | select(.status == "survived" or .status == "no_coverage")
  | "\(.location.file):\(.location.line)  \(.status)  \(.description)"
    + (if .patch then
         (.patch.before | split("\n")) as $b
         | (.patch.after | split("\n")) as $a
         | only("-"; $b; $a) + only("+"; $a; $b)
       else "" end)
' "$report")

if [[ -n "$failing" ]]; then
  echo
  echo "scripts/mutate.sh: the selected lib/ lines have untested behaviour:"
  echo
  echo "$failing"
  echo
  echo "Add or tighten a test that fails for each mutant above, in this change."
  echo "See CLAUDE.md \"Mutation testing\" for the documented exceptions."
  exit 1
fi

echo "scripts/mutate.sh: no mutant of the selected lib/ lines survived."

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
#                                   included (muex --since). The
#                                   pre-push hook runs this mode on a
#                                   pushed tip with no mutation record.
#   scripts/mutate.sh staged      — mutate only the lib/**/*.ex lines
#                                   staged for the next commit (muex
#                                   --staged). The lefthook pre-commit
#                                   hook runs this mode.
#   scripts/mutate.sh <path…>     — mutate every line of the named
#                                   lib/**/*.ex files, refusing any
#                                   other path.
#
# Every mode fails when any mutant survives or no test reaches it.
#
# A pass of either gated mode records the contents it judged with
# scripts/checked-trees.sh --mutated when they are known to be gated
# throughout: see record_if_gated.
#
# Pass extra muex flags through after `--`:
#   scripts/mutate.sh changed -- --concurrency 4

set -euo pipefail

# Stop at Ctrl-C, however muex exited: bash carries on after a child that
# handled SIGINT itself, as the BEAM does, and the run could then judge, and
# record, a report whose mutants never all ran. Dying by SIGINT, not exiting,
# makes a calling bash stop too.
trap 'trap - INT; kill -INT $$' INT

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

# A tree whose every lib line since origin/main has passed this gate is
# recorded, so the pre-push hook need not mutate it again. Which trees
# qualify is decided before the run, in `tree` (the contents judged) and
# `record`; the worktree must still hold exactly `tree` afterwards, since
# muex tests the files on disk.
tree=
record=false
holds() { bash scripts/checked-trees.sh holds "$tree"; }

record_if_gated() {
  if [[ "$record" == true ]] && holds; then
    bash scripts/checked-trees.sh --mutated mark "$tree"
  fi
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
label=selected
gate=false
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
    index=$(git rev-parse --path-format=absolute --git-path index)
    # A run against origin/main on exactly HEAD judges every lib line HEAD
    # changed since main.
    if [[ "$base" == origin/main ]] && tree=$(git rev-parse --verify --quiet 'HEAD^{tree}') && holds; then
      record=true
    fi
    if ! has_added_lines --merge-base "$base"; then
      echo "scripts/mutate.sh: no lib/**/*.ex lines changed vs $base — nothing to mutate."
      record_if_gated
      exit 0
    fi
    collect_files lib '*.ex'
    scope_args=(--since "$base")
    muex_env=(GIT_INDEX_FILE="$index")
    label=changed
    gate=true
    ;;
  staged)
    # During `git commit -a` or `git commit <paths>`, GIT_INDEX_FILE names
    # a temporary index holding the commit's contents. --git-path resolves
    # it (or the usual index) to an absolute path, which muex --staged
    # reads after the rest of git's hook environment is cleared below.
    index=$(git rev-parse --path-format=absolute --git-path index)
    tree=$(git write-tree)
    # The commit's other lib lines come from HEAD, so its contents are
    # gated throughout only when HEAD's were, or HEAD is in origin/main. A root
    # commit stages every line.
    if holds && { ! git rev-parse --verify --quiet HEAD >/dev/null ||
      bash scripts/checked-trees.sh --mutated has HEAD ||
      git merge-base --is-ancestor HEAD origin/main 2>/dev/null; }; then
      record=true
    fi
    if ! has_added_lines --cached; then
      echo "scripts/mutate.sh: no lib/**/*.ex lines staged — nothing to mutate."
      record_if_gated
      exit 0
    fi
    collect_files lib '*.ex'
    scope_args=(--staged)
    muex_env=(GIT_INDEX_FILE="$index")
    label=staged
    gate=true
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
    bun scripts/mutate-paths.ts "${files[@]}"
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
# A flag such as --max-mutations can narrow the run, so it records nothing.
[[ ${#extra_args[@]} -eq 0 ]] || record=false

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

run_mutate() {
  MIX_ENV=test mix deps.get
  # The suite needs node_modules, which a fresh worktree lacks.
  pnpm install --frozen-lockfile --ignore-scripts --prefer-offline
  MIX_ENV=test mix compile --warnings-as-errors

  # muex's `--files` accepts comma-separated globs/paths.
  joined=$(IFS=,; echo "${files[*]}")
  # --coverage-guided runs each mutant against the test files that execute
  # its line, and skips mutants on lines no test executes (reported as
  # no coverage). For lines `:cover` has no data for, it falls back to
  # muex's dependency analysis, then to every test file it is given. muex
  # runs as many test BEAMs at once as there are cores; like
  # scripts/mix-test.sh, cap them at half (at least one) so a commit leaves
  # the machine usable. A --concurrency after `--` overrides this.
  jobs=$(($(getconf _NPROCESSORS_ONLN) / 2))
  ((jobs >= 1)) || jobs=1
  # To find which tests execute which lines, muex first runs every test file
  # it is given under :cover, whatever lines are mutated. The files under
  # test/scripts drive shell scripts in subprocesses, so in their own BEAM
  # they execute only the app-start lines every test file executes; leaving
  # them out halves that run without changing which mutants are killed.
  tests=$(find test -name '*_test.exs' -type f -not -path 'test/scripts/*' | sort | paste -sd , -)
  # Every selected line counts, so --no-filter keeps muex from skipping a
  # file it rates too simple to be worth mutating, and --no-optimize from
  # dropping the mutants of a function it rates too simple.
  muex=(mix muex --files "$joined" --test-paths "$tests" --coverage-guided
    --concurrency "$jobs" --no-filter --no-optimize "${scope_args[@]}")

  # Every mode judges the run from muex's JSON report rather than its
  # score: muex's default --fail-at passes a run with survivors, its score
  # ignores no-coverage mutants, and lines that yield no mutants have
  # nothing to score, and must pass. muex prints the report's path, so the
  # report is kept, in _build/, until the next run replaces it. muex
  # strips GIT_INDEX_FILE from the test runs it starts.
  mkdir -p _build
  report="$PWD/_build/mutate-$label.json"
  # muex writes no report when there is nothing to mutate, as for staged
  # comments or lib/meerkat/application.ex alone, so an earlier run's
  # report must not be left for this run to judge.
  rm -f "$report"
  env "${muex_env[@]}" "${muex[@]}" --fail-at 0 \
    --format json --output "$report" "${extra_args[@]}"

  if [[ ! -f "$report" ]]; then
    echo "scripts/mutate.sh: the $label lib/ lines produce no mutants."
    record_if_gated
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

  # A survivor is a judged line whose behaviour the tests do not pin
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
    echo "scripts/mutate.sh: $label lib/ lines have untested behaviour:"
    echo
    echo "$failing"
    echo
    echo "Add or tighten a test that fails for each mutant above, in this $([[ $mode == staged ]] && echo commit || echo branch)."
    echo "See CLAUDE.md \"Mutation testing\" for the documented exceptions."
    exit 1
  fi

  record_if_gated
  echo "scripts/mutate.sh: no mutant of the $label lib/ lines survived."
}

# Like scripts/check.sh, the gate holds a slot from scripts/gate-lock.sh
# and runs in a subshell that closes the slot's fd 9 first and ends at
# Ctrl-C, after which this shell's own trap stops this script.
if [[ "$gate" == true ]]; then
  source scripts/gate-lock.sh
  gate_lock
fi
(
  exec 9>&-
  trap 'exit 130' INT
  run_mutate
)

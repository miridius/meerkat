#!/usr/bin/env bash
# Mutation testing for meerkat.
#
# Runs `mix muex` against the meerkat domain code. muex rewrites
# operators / literals one at a time and re-runs the test suite
# against each rewrite. A rewrite the suite still passes against
# is an uncovered behaviour — fix the test or the code.
#
# Modes:
#   scripts/mutate.sh             — mutate every lib/meerkat/*.ex
#                                   (skips application — supervisor
#                                   plumbing). Slow; run before
#                                   opening a PR.
#   scripts/mutate.sh changed     — mutate ONLY lib/meerkat/*.ex files
#                                   changed on the current branch vs
#                                   origin/main. Run during local
#                                   iteration.
#   scripts/mutate.sh <path…>     — mutate the named files.
#
# Pass extra muex flags through after `--`:
#   scripts/mutate.sh changed -- --fail-at 95 --concurrency 4

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

mode=${1:-default}
shift || true

declare -a files
case "$mode" in
  default)
    # Capture into a tempfile + check exit status — process-subst
    # `< <(find …)` would swallow a find failure (set -e doesn't
    # propagate through it).
    listing=$(mktemp)
    trap 'rm -f "$listing"' EXIT
    if ! find lib/meerkat -maxdepth 1 -name '*.ex' -type f | sort > "$listing"; then
      echo "scripts/mutate.sh: find under lib/meerkat failed." >&2
      exit 2
    fi
    while IFS= read -r f; do
      skip_file "$f" || files+=("$f")
    done < "$listing"
    ;;
  changed)
    base="${BASE_BRANCH:-origin/main}"
    if ! git rev-parse --verify "$base" >/dev/null 2>&1; then
      echo "scripts/mutate.sh: base ref '$base' not found; fetch origin first." >&2
      exit 2
    fi
    listing=$(mktemp)
    trap 'rm -f "$listing"' EXIT
    if ! git diff --name-only "$base"...HEAD -- 'lib/meerkat/*.ex' > "$listing"; then
      echo "scripts/mutate.sh: git diff vs $base failed." >&2
      exit 2
    fi
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      skip_file "$f" && continue
      [[ -f "$f" ]] || continue
      files+=("$f")
    done < "$listing"
    if [[ ${#files[@]} -eq 0 ]]; then
      echo "scripts/mutate.sh: no lib/meerkat/*.ex files changed vs $base — nothing to mutate."
      exit 0
    fi
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

echo "scripts/mutate.sh: mutating ${#files[@]} file(s):"
printf '  %s\n' "${files[@]}"

MIX_ENV=test mix deps.get
MIX_ENV=test mix compile --warnings-as-errors

# muex's `--files` accepts comma-separated globs/paths.
joined=$(IFS=,; echo "${files[*]}")
mix muex --files "$joined" "${extra_args[@]}"

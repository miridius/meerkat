#!/usr/bin/env bash
# Compile once with MIX_ENV=test, then run each test/**/*_test.exs file as
# its own `mix test --no-compile` BEAM through scripts/run-test-file.sh,
# with parallelism capped at half the online cores (minimum one).
#
# Many modules are `async: false` because they change process-wide state:
# environment variables, application env, or singleton processes. One `mix
# test` runs them serially; separate BEAMs share none of that state, so those
# files can run together. Half the cores took as long as all of them and
# loads the machine less.
#
# Each file also takes one of as many test-file slots, which all runs of this
# script in all worktrees share, so two at once run no more files together
# than one. Test files contend for more than the CPU: with 9 at once on 18
# cores, the CPU stayed half idle, yet the files took 1.7 times as long in all
# as with 2.
#
# Each file's wall and CPU time is kept. Once every file has passed,
# scripts/test-file-times.ts runs each file over the limit in
# scripts/test-file-limit.json that has no entry there with a reason again,
# and fails it if it is still over.
#
# On failure, print each failing file's output, list the failing files, and
# exit non-zero. CI and the pre-commit gate both run this script, so each
# runs the files the same way.
set -euo pipefail

cd "$(dirname "$0")/.."

export MIX_ENV=test
mix compile

logs=$(mktemp -d)
trap 'rm -rf "$logs"' EXIT
export logs

# Sort by line count, largest first, so the longest runs start early rather than pile up at the end.
files=$(find test -name '*_test.exs' -type f -exec wc -l {} + | { grep -v ' total$' || true; } | sort -nr | awk '{print $2}')
if [[ -z "$files" ]]; then
  echo "mix test: no *_test.exs files under test/." >&2
  exit 1
fi

# Half the online cores rounds to 0 on one core; since `xargs -P 0` runs as
# many processes as possible, clamp the worker count to 1.
jobs=$(($(getconf _NPROCESSORS_ONLN) / 2))
((jobs >= 1)) || jobs=1
export jobs

# Each job writes its exit status beside its log; these status files, not
# xargs' exit status, determine success. Files xargs never runs have no
# status file and count as failed.
xargs -P "$jobs" -n 1 bash -c '
  log="$logs/$1"
  mkdir -p "$(dirname "$log")"
  status=0
  bash scripts/run-test-file.sh "$jobs" "$1" "$log.secs" >"$log" 2>&1 || status=$?
  echo "$status" >"$log.status"
' _ <<<"$files" || true

failed=()
for file in $files; do
  log="$logs/$file"
  if [[ ! -f "$log.status" ]]; then
    failed+=("$file")
    echo
    echo "=== mix test $file did not finish ==="
  elif [[ "$(cat "$log.status")" != 0 ]]; then
    failed+=("$file")
    echo
    echo "=== mix test $file ==="
    cat "$log"
  fi
done

count=$(wc -l <<<"$files" | tr -d ' ')
if [[ ${#failed[@]} -gt 0 ]]; then
  echo
  echo "mix test: ${#failed[@]} of $count test files failed:"
  printf '  %s\n' "${failed[@]}"
  exit 1
fi

# Fails a file still over the per-file time limit when run again.
# shellcheck disable=SC2086
bun scripts/test-file-times.ts "$logs" "$jobs" $files
echo "mix test: all $count test files passed."

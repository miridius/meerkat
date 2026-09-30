#!/usr/bin/env bash
# Runs the whole ExUnit suite, as `mix test` would, with each test file in
# its own BEAM, on half the cores at a time.
#
# Most of the suite's modules are `async: false`, because they change
# process-wide state: environment variables, application env, singleton
# processes. A single `mix test` runs those modules one after another. In
# separate BEAMs they share none of that state, so they can run at once.
# Half the cores ran the suite as fast as all of them did, and loads the
# machine less, so the suite's timing-sensitive tests keep their margin.
#
# Prints each failing file's output, and exits non-zero if any file fails.
# CI runs plain `mix test`, which also checks the files pass in one BEAM.
set -euo pipefail

cd "$(dirname "$0")/.."

export MIX_ENV=test
mix compile

logs=$(mktemp -d)
trap 'rm -rf "$logs"' EXIT
export logs

# Largest files first, so the longest runs are not left until the end.
files=$(find test -name '*_test.exs' -type f -exec wc -l {} + | grep -v ' total$' | sort -nr | awk '{print $2}')

# Each job records its exit status beside its output.
xargs -P "$(($(getconf _NPROCESSORS_ONLN) / 2))" -n 1 bash -c '
  log="$logs/$(tr / _ <<<"$1")"
  status=0
  mix test --no-compile "$1" >"$log" 2>&1 || status=$?
  echo "$status" >"$log.status"
' _ <<<"$files"

failed=()
for file in $files; do
  log="$logs/$(tr / _ <<<"$file")"
  if [[ "$(cat "$log.status")" != 0 ]]; then
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
echo "mix test: all $count test files passed."

#!/usr/bin/env bash
# Runs one test file for scripts/mix-test.sh once it holds one of <slots>
# test-file slots from scripts/gate-lock.sh, which all test runs in all
# worktrees of the repo share. Writes the file's wall time in whole seconds,
# from when it holds its slot, to <seconds file>, and exits with mix test's
# status.
#
# The test BEAM runs four schedulers that do not busy-wait (`+S 4 +sbwt
# none`); ELIXIR_ERL_OPTIONS already set comes after them, so it wins. Timed
# file by file, that used a fifth to a third less CPU in no more wall time.
#
# Usage: run-test-file.sh <slots> <test file> <seconds file>
set -euo pipefail

source "$(dirname "$0")/gate-lock.sh"
test_file_lock "$1"

start=$(date +%s)
status=0
# A subshell that closes the slot's fd first, as in scripts/check.sh, so
# nothing the test starts can keep the slot once this shell is gone.
(
  exec 9>&-
  ELIXIR_ERL_OPTIONS="+S 4 +sbwt none ${ELIXIR_ERL_OPTIONS:-}" exec mix test --no-compile "$2"
) || status=$?
echo $(($(date +%s) - start)) >"$3"
exit "$status"

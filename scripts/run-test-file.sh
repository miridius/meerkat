#!/usr/bin/env bash
# Runs one test file for scripts/mix-test.sh, or again for
# scripts/test-file-times.ts, once it holds one of <slots>
# test-file slots from scripts/gate-lock.sh, which all test runs in all
# worktrees of the repo share. Writes the file's wall, user and system
# seconds, from when it holds its slot, to <seconds file>, and exits with mix
# test's status. The CPU seconds count the test BEAM and the processes the
# shell and BEAM wait for, but not the programs the BEAM starts through
# ports: erl_child_setup, which reaps those, outlives the BEAM unwaited for.
#
# The test BEAM runs four schedulers that do not busy-wait (`+S 4 +sbwt
# none`); ELIXIR_ERL_OPTIONS already set comes after them, so it wins. Timed
# file by file, that used a fifth to a third less CPU in no more wall time.
#
# It also skips mix's build lock (MIX_OS_CONCURRENCY_LOCK=0): mix test takes
# it even with --no-compile, so the test BEAMs queued on it as they started.
# scripts/mix-test.sh has compiled under the lock already, so they compile
# nothing.
#
# Usage: run-test-file.sh <slots> <test file> <seconds file>
set -euo pipefail

source "$(dirname "$0")/gate-lock.sh"
test_file_lock "$1"

# mix test runs without the slot's fd, as in scripts/check.sh, so nothing the
# test starts can keep the slot once this shell is gone. `time` reports to
# <seconds file>; the test's stderr goes on to fd 4. Under `time` a subshell
# would report from itself, after its own redirections, or not at all if it
# ends in exec.
exec 4>&2
TIMEFORMAT='%R %U %S'
{
  time MIX_OS_CONCURRENCY_LOCK=0 ELIXIR_ERL_OPTIONS="+S 4 +sbwt none ${ELIXIR_ERL_OPTIONS:-}" \
    mix test --no-compile "$2" 9>&- 2>&4 4>&-
} 2>"$3"

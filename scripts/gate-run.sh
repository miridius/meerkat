#!/usr/bin/env bash
# gate-run.sh <command>...: runs the command in one of the repo's two gate
# slots from scripts/gate-lock.sh, for scripts/check.ts and scripts/mutate.sh,
# and exits as it does.
#
# This shell holds the slot until it exits. The command runs in a subshell
# that closes the slot's fd first, so nothing it starts can keep the slot
# once this shell is gone; `"$@" 9>&-` would not do, as bash keeps a copy of
# fd 9 that its subshells, and under bash 3.2 every child, inherit.
set -euo pipefail

# Stop at Ctrl-C, however the command exited: bash carries on after a child
# that handled SIGINT itself, as the BEAM does. Dying by SIGINT, not exiting,
# makes a calling shell stop too. The subshell resets the INT trap, so it gets
# one that ends it at Ctrl-C, after which this shell's own trap stops it.
trap 'trap - INT; kill -INT $$' INT

source "$(dirname "$0")/gate-lock.sh"
gate_lock
(
  exec 9>&-
  trap 'exit 130' INT
  "$@"
)

# Sourced by scripts/check.sh and scripts/mutate.sh, so at most two gates in
# all worktrees of a repo run their heavy checks at once.
#
# gate_lock: returns once this shell holds one of the gate's two slots, an
# flock(2) taken with macOS lockf(1) on a file in meerkat-gate-lock in the
# git common dir. The slot stays open on fd 9 until the shell exits, and the
# kernel frees it then, however the shell exits, once no other process has
# fd 9's file open. So the gate runs its checks in a subshell that closes
# fd 9 first: a child that outlives a killed gate cannot keep the slot.
#
# Bash rather than TypeScript only until check.sh and mutate.sh move to
# TypeScript: the lock must be held by the gate's own process.
#
# Waiting gates queue on a third lock, on fd 8: only the one at the head of
# the queue tries the slots, so a newcomer never takes a slot ahead of it;
# which waiter moves to the head next is not ordered. Every lock is tried
# without waiting, once a second, because lockf(1) on an fd spins a core
# while it blocks. Each waiting gate prints that it is waiting, and gives up
# after MEERKAT_GATE_LOCK_TIMEOUT seconds (default an hour).
gate_lock() {
  local dir slot status queued=false waited=false start=$SECONDS
  local timeout=${MEERKAT_GATE_LOCK_TIMEOUT:-3600}
  dir="$(git rev-parse --path-format=absolute --git-common-dir)/meerkat-gate-lock"
  mkdir -p "$dir"
  exec 8>>"$dir/queue"

  while true; do
    if [[ "$queued" == false ]]; then
      status=0
      gate_lock_try 8 "$dir/queue" || status=$?
      ((status != 1)) || return 1
      ((status != 0)) || queued=true
    fi
    if [[ "$queued" == true ]]; then
      for slot in 1 2; do
        exec 9>>"$dir/slot$slot"
        status=0
        gate_lock_try 9 "$dir/slot$slot" || status=$?
        ((status != 1)) || return 1
        if ((status == 0)); then
          exec 8>&-
          [[ "$waited" == false ]] || echo "gate-lock: got a slot after $((SECONDS - start))s." >&2
          return 0
        fi
      done
      exec 9>&-
    fi
    gate_lock_waiting
    if ((SECONDS - start >= timeout)); then
      exec 8>&-
      echo "gate-lock: no slot came free in ${timeout}s; giving up. Set MEERKAT_GATE_LOCK_TIMEOUT to wait longer." >&2
      return 1
    fi
    sleep 1
  done
}

# Tries once to lock the file open on fd $1, named $2. Returns 0 once it is
# locked, 75 (lockf's EX_TEMPFAIL) while another process holds it, and 1,
# saying why, when it cannot be locked.
gate_lock_try() {
  local status=0
  lockf -s -t 0 "$1" || status=$?
  ((status != 0 && status != 75)) || return "$status"
  echo "gate-lock: cannot lock $2." >&2
  return 1
}

gate_lock_waiting() {
  [[ "$waited" == false ]] || return 0
  waited=true
  echo "gate-lock: 2 gates are already running checks in this repo; waiting for one to finish." >&2
}

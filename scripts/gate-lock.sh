# Sourced by scripts/check.sh and scripts/mutate.sh, so at most
# MEERKAT_GATE_SLOTS gates in all worktrees of a repo run their heavy checks
# at once. It defaults to a quarter of the online cores, minimum one. A gate
# spends most of its time waiting rather than computing: on an 18-core Mac,
# scripts/mix-test.sh used about 140 CPU seconds over 23 minutes. Its bursts
# run half the cores' worth of BEAMs, so a quarter keeps two gates' bursts
# at once within the cores.
#
# gate_lock: returns once this shell holds one of the gate's slots, an
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
  local dir slot slots status queued=false waited=false start=$SECONDS
  local timeout=${MEERKAT_GATE_LOCK_TIMEOUT:-3600}
  slots=$(gate_lock_slots) || return 1
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
      for ((slot = 1; slot <= slots; slot++)); do
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

# Prints how many gates may run at once: MEERKAT_GATE_SLOTS when set, which
# must be a positive integer, else a quarter of the online cores, minimum one.
gate_lock_slots() {
  local slots=${MEERKAT_GATE_SLOTS:-}
  if [[ -z "$slots" ]]; then
    slots=$(($(getconf _NPROCESSORS_ONLN) / 4))
    ((slots >= 1)) || slots=1
  elif [[ ! "$slots" =~ ^[0-9]+$ ]] || ((10#$slots < 1)); then
    echo "gate-lock: MEERKAT_GATE_SLOTS must be a whole number of at least 1, not '$slots'." >&2
    return 1
  fi
  echo $((10#$slots))
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
  echo "gate-lock: $slots gates are already running checks in this repo; waiting for one to finish." >&2
}

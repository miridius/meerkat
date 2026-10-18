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
# Gates wait their turn first come, first served. Each takes a ticket in
# meerkat-gate-lock/waiting, named for the microsecond it started waiting
# and its pid, and holds a lock on it on fd 8; only the gate with the
# earliest live ticket tries the slots. A ticket is locked before it gets
# its name, so a ticket without a lock belongs to a gate that has died, and
# the next gate to find it deletes it; no later ticket can take its name.
# Every lock is tried without waiting, once a second, because lockf(1) on
# an fd spins a core while it blocks. Each waiting gate prints that it is
# waiting, and gives up after MEERKAT_GATE_LOCK_TIMEOUT seconds (default an
# hour).
gate_lock() {
  local dir ticket slot status waited=false start=$SECONDS
  local timeout=${MEERKAT_GATE_LOCK_TIMEOUT:-3600}
  dir="$(git rev-parse --path-format=absolute --git-common-dir)/meerkat-gate-lock"
  mkdir -p "$dir/waiting"
  gate_lock_ticket || return 1

  while true; do
    status=0
    gate_lock_first || status=$?
    ((status != 1)) || { gate_lock_leave; return 1; }
    if ((status == 0)); then
      for slot in 1 2; do
        exec 9>>"$dir/slot$slot"
        status=0
        gate_lock_try 9 "$dir/slot$slot" || status=$?
        ((status != 1)) || { gate_lock_leave; return 1; }
        if ((status == 0)); then
          gate_lock_leave
          [[ "$waited" == false ]] || echo "gate-lock: got a slot after $((SECONDS - start))s." >&2
          return 0
        fi
      done
      exec 9>&-
    fi
    gate_lock_waiting
    if ((SECONDS - start >= timeout)); then
      gate_lock_leave
      echo "gate-lock: no slot came free in ${timeout}s; giving up. Set MEERKAT_GATE_LOCK_TIMEOUT to wait longer." >&2
      return 1
    fi
    sleep 1
  done
}

# Takes this gate's ticket: locks a file on fd 8 under a name no ticket
# glob matches, then renames it to its ticket name, which keeps the lock.
gate_lock_ticket() {
  local pending="$dir/waiting/.$$"
  ticket="$dir/waiting/${EPOCHREALTIME//[!0-9]/}.$$"
  exec 8>"$pending"
  gate_lock_try 8 "$pending" || { exec 8>&-; rm -f "$pending"; return 1; }
  mv "$pending" "$ticket" || { exec 8>&-; rm -f "$pending"; return 1; }
}

# Returns 0 when this gate holds the earliest live ticket, 75 while an
# earlier one is live, and 1 when a ticket cannot be checked. It deletes
# each earlier ticket whose gate has died. Every ticket name starts with
# the same number of digits, so the glob lists them in the order taken.
gate_lock_first() {
  local other status
  for other in "$dir/waiting/"[0-9]*; do
    [[ "$other" != "$ticket" ]] || return 0
    # Its gate may have deleted it since the glob listed it.
    { exec 7<"$other"; } 2>/dev/null || continue
    status=0
    gate_lock_try 7 "$other" || status=$?
    ((status != 0)) || rm -f "$other"
    exec 7<&-
    ((status == 0)) || return "$status"
  done
  echo "gate-lock: this gate's ticket $ticket is gone." >&2
  return 1
}

# Drops this gate's ticket.
gate_lock_leave() {
  rm -f "$ticket"
  exec 8>&-
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

# Sourced by scripts/check.sh and scripts/mutate.sh, so at most two gates in
# all worktrees of a repo run their heavy checks at once, and by
# scripts/run-test-file.sh, so all test runs in those worktrees together run
# at most half the online cores' worth of test files at once.
#
# gate_lock: returns once this shell holds one of the gate's two slots, an
# flock(2) taken with macOS lockf(1) on a file in meerkat-gate-lock in the
# git common dir. The slot stays open on fd 9 until the shell exits, and the
# kernel frees it then, however the shell exits, once no other process has
# fd 9's file open. So the gate runs its checks in a subshell that closes
# fd 9 first: a child that outlives a killed gate cannot keep the slot.
#
# test_file_lock: the same for one of the given number of test-file slots,
# in meerkat-gate-lock/files, waiting silently, and taking a free slot
# without a ticket while no ticket waits.
#
# Bash rather than TypeScript only until check.sh, mutate.sh and
# run-test-file.sh move to TypeScript: the lock must be held by the process
# that sourced this file.
#
# Gates wait their turn first come, first served. Each takes a ticket in
# meerkat-gate-lock/waiting, named for the microsecond it started waiting
# (the start of the second under bash before 5, so such a gate can go
# ahead of one that started earlier in that second) and its pid, and holds
# a lock on it on fd 8; only the gate with the earliest live ticket tries
# the slots. A ticket is locked before it gets its name, so a ticket
# without a lock belongs to a gate that has died, and the next gate to find
# it deletes it; no later ticket can take its name. Every lock is tried
# without waiting, once a second, because lockf(1) on an fd spins a core
# while it blocks. Each waiting gate prints that it is waiting, and gives
# up after MEERKAT_GATE_LOCK_TIMEOUT seconds (default an hour).
#
# Gates on the script from before tickets (#90) wait for a lock on
# meerkat-gate-lock/queue and try the slots once they hold it, so the gate
# with the earliest ticket also takes that lock when it is free, on fd 6,
# and holds it until it gets a slot, stops being the earliest, or gives
# up; while one of those gates holds it, the two race for the slots. This
# can go once no branch predates #90. Test-file slots have no such lock.
gate_lock() {
  gate_lock_slots meerkat-gate-lock 2 "gate slots" true
}

# test_file_lock <slot count>: the slot count is scripts/mix-test.sh's
# parallelism.
test_file_lock() {
  gate_lock_slots meerkat-gate-lock/files "$1" "" false
}

# gate_lock_slots <dir in the git common dir> <slot count> <what to call the
# slots when waiting, or "" to wait silently> <whether to take the queue lock>
gate_lock_slots() {
  local dir ticket slot status queued=false waited=false start=$SECONDS
  local count=$2 noun=$3 legacy=$4
  local timeout=${MEERKAT_GATE_LOCK_TIMEOUT:-3600}
  dir="$(git rev-parse --path-format=absolute --git-common-dir)/$1"
  mkdir -p "$dir/waiting"

  # With no ticket waiting, a free slot overtakes no one, so slots without
  # the old script's lock are tried at once, without a ticket: tickets taken
  # together would otherwise each wait a second behind the one before.
  if [[ "$legacy" == false ]] && ! compgen -G "$dir/waiting/[0-9]*" >/dev/null; then
    status=0
    gate_lock_take || status=$?
    ((status == 75)) || return "$status"
  fi

  gate_lock_ticket || return 1

  while true; do
    status=0
    gate_lock_first || status=$?
    ((status != 1)) || { gate_lock_leave; return 1; }
    if ((status == 0)); then
      gate_lock_queue || { gate_lock_leave; return 1; }
      status=0
      gate_lock_take || status=$?
      ((status != 1)) || { gate_lock_leave; return 1; }
      if ((status == 0)); then
        gate_lock_leave
        [[ "$waited" == false ]] || echo "gate-lock: got a slot after $((SECONDS - start))s." >&2
        return 0
      fi
    elif [[ "$queued" == true ]]; then
      # A ticket that sorts ahead of this one has appeared since.
      exec 6>&-
      queued=false
    fi
    gate_lock_waiting
    if ((SECONDS - start >= timeout)); then
      gate_lock_leave
      echo "gate-lock: got no slot in ${timeout}s; giving up. Set MEERKAT_GATE_LOCK_TIMEOUT to wait longer." >&2
      return 1
    fi
    sleep 1
  done
}

# Tries each slot once, keeping the first it locks open on fd 9. Returns 0
# once it holds one, 75 while every slot is taken, and 1 when one cannot be
# locked.
gate_lock_take() {
  local status
  for ((slot = 1; slot <= count; slot++)); do
    exec 9>>"$dir/slot$slot"
    status=0
    gate_lock_try 9 "$dir/slot$slot" || status=$?
    ((status == 75)) || return "$status"
  done
  exec 9>&-
  return 75
}

# Takes this gate's ticket: locks a file on fd 8 under a name no ticket
# glob matches, then renames it to its ticket name, which keeps the lock.
gate_lock_ticket() {
  local pending="$dir/waiting/.$$" now=${EPOCHREALTIME:-}
  now=${now//[!0-9]/}
  if [[ -z "$now" ]]; then
    now=$(date +%s) || { echo "gate-lock: cannot read the time." >&2; return 1; }
    now+=000000
  fi
  ticket="$dir/waiting/$now.$$"
  exec 8>"$pending"
  gate_lock_try 8 "$pending" || { exec 8>&-; rm -f "$pending"; return 1; }
  mv "$pending" "$ticket" || { exec 8>&-; rm -f "$pending"; return 1; }
}

# Returns 0 when this gate holds the earliest live ticket, 75 while an
# earlier one is live, and 1, saying why, when an earlier ticket cannot be
# checked or this gate's own is gone. It deletes each earlier ticket whose
# gate has died. Every ticket name starts with the same number of digits,
# so the glob lists them in the order taken.
gate_lock_first() {
  local other status
  for other in "$dir/waiting/"[0-9]*; do
    [[ "$other" != "$ticket" ]] || return 0
    if ! { exec 7<"$other"; } 2>/dev/null; then
      # Its gate may have deleted it since the glob listed it.
      [[ -e "$other" ]] || continue
      echo "gate-lock: cannot open $other." >&2
      return 1
    fi
    status=0
    gate_lock_try 7 "$other" || status=$?
    ((status != 0)) || rm -f "$other"
    exec 7<&-
    ((status == 0)) || return "$status"
  done
  echo "gate-lock: this gate's ticket $ticket is gone." >&2
  return 1
}

# Takes the lock gates on the old script wait for, unless this gate holds
# it already or these slots have none. Returns 0 once it holds it or while
# one of those gates does, and 1 when it cannot be locked.
gate_lock_queue() {
  local status=0
  [[ "$legacy" == true && "$queued" == false ]] || return 0
  exec 6>>"$dir/queue"
  gate_lock_try 6 "$dir/queue" || status=$?
  ((status != 1)) || return 1
  if ((status == 0)); then queued=true; else exec 6>&-; fi
}

# Drops this gate's ticket and the old script's queue lock.
gate_lock_leave() {
  rm -f "$ticket"
  exec 8>&- 6>&-
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
  [[ -n "$noun" && "$waited" == false ]] || return 0
  waited=true
  echo "gate-lock: waiting for one of this repo's $count $noun, behind any gates that started waiting first." >&2
}

# Sourced by scripts/check.sh and scripts/mutate.sh, so at most two gates in
# all worktrees of a repo run their heavy checks at once.
#
# gate_lock: returns once this shell holds one of the gate's two slots, an
# flock(2) taken with macOS lockf(1) on a file in meerkat-gate-lock in the
# git common dir. The slot stays open on fd 9 until the shell exits, and the
# kernel frees it then, however the shell exits. A child inherits fd 9 and
# would hold the slot for as long as it outlives the gate, so the gate runs
# its checks with `9>&-`; bash keeps its own copy of fd 9 meanwhile, so the
# shell still holds the slot.
#
# Bash rather than TypeScript only until check.sh and mutate.sh move to
# TypeScript: the lock must be held by the gate's own process.
#
# Waiting gates queue on a third lock, on fd 8, and take slots in turn: only
# the one at the head of the queue tries the slots, twice a second. Each
# prints that it is waiting.
gate_lock() {
  local dir slot status waited=false start=$SECONDS
  dir="$(git rev-parse --path-format=absolute --git-common-dir)/meerkat-gate-lock"
  mkdir -p "$dir"

  # Newcomers queue too, so none takes a slot ahead of a gate already waiting.
  exec 8>>"$dir/queue"
  if ! lockf -s -t 0 8; then
    gate_lock_waiting
    lockf -s 8 || {
      echo "gate-lock: cannot lock $dir/queue." >&2
      return 1
    }
  fi
  while true; do
    for slot in 1 2; do
      exec 9>>"$dir/slot$slot"
      status=0
      lockf -s -t 0 9 || status=$?
      if ((status == 0)); then
        exec 8>&-
        [[ "$waited" == false ]] || echo "gate-lock: got a slot after $((SECONDS - start))s." >&2
        return 0
      fi
      # EX_TEMPFAIL: another gate holds this slot.
      ((status == 75)) || {
        echo "gate-lock: cannot lock $dir/slot$slot." >&2
        return 1
      }
    done
    exec 9>&-
    gate_lock_waiting
    sleep 0.5
  done
}

gate_lock_waiting() {
  [[ "$waited" == false ]] || return 0
  waited=true
  echo "gate-lock: 2 gates are already running checks in this repo; waiting for one to finish." >&2
}

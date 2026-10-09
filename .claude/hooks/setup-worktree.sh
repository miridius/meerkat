#!/usr/bin/env bash
# SessionStart, SubagentStart and PostToolUse(EnterWorktree) hook:
# installs any missing Hex or JS dependencies in the checkout Claude
# starts in or enters, before Claude works there, so a fresh worktree can
# build and test and its git hooks find lefthook (`pnpm install` installs
# it). The hook input's `cwd` is that checkout; CLAUDE_PROJECT_DIR stays
# the session's starting project.
#
# Mix deps count as missing when there is no deps/, or a mix.lock git dep
# has no deps/<name>/.git (the nested repo a copied deps/ lacks). mix.lock
# also lists optional deps that are never fetched, so other entries are
# not checked. JS deps count as missing when node_modules has no pnpm
# state.
# In a linked worktree, the hook also recreates each symlink under the
# main checkout's _build/ that is missing from the worktree's copy, where
# the link's parent directory exists in the worktree: Claude Code's
# .worktreeinclude copy leaves symlinks out, and Mix recreates a dep's
# priv/ link only when it recompiles that dep.
# Parallel subagents can start in one checkout at once, so each run holds
# a per-checkout lock; the kernel drops it if the hook is killed.
# Nothing is printed when nothing is missing. A failed step is reported
# to Claude as additional context, never blocking the session.
set -uo pipefail

input=$(cat)
event=$(jq -r '.hook_event_name // empty' <<<"$input" 2>/dev/null)
cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null || exit 0
[ -f mix.lock ] && [ -f pnpm-lock.yaml ] || exit 0

lock=$(git rev-parse --path-format=absolute --git-path meerkat-setup.lock 2>/dev/null) || exit 0
exec 9>"$lock"
# Tried once a second rather than waited on: lockf(1) on an fd spins a core
# while it blocks. Exit 75 means another run holds the lock.
status=75
while ((status == 75)); do
  status=0
  lockf -s -t 0 9 || status=$?
  ((status != 75)) || sleep 1
done

mix_deps_missing() {
  local name
  [ -d deps ] || return 0
  for name in $(sed -nE 's/^  "([^"]+)": \{:git,.*/\1/p' mix.lock); do
    [ -e "deps/$name/.git" ] || return 0
  done
  return 1
}

failures=""
log=$(mktemp)

run() {
  if ! "$@" >"$log" 2>&1 9>&-; then
    failures+="\`$*\` failed in $cwd:"$'\n'"$(tail -n 20 "$log")"$'\n'
  fi
}

if mix_deps_missing; then run mix deps.get; fi
if [ ! -f node_modules/.modules.yaml ]; then
  run pnpm install --frozen-lockfile --prefer-offline
fi
main=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
if [ "$main" != "$(git rev-parse --show-toplevel)" ] && [ -d "$main/_build" ]; then
  while IFS= read -r link; do
    link=${link#"$main/"}
    if [ -d "$(dirname "$link")" ] && [ ! -L "$link" ] && [ ! -e "$link" ]; then
      run ln -s "$(readlink "$main/$link")" "$link"
    fi
  done < <(find "$main/_build" -type l)
fi
rm -f "$log"

if [ -n "$failures" ]; then
  jq -n --arg event "$event" --arg msg "Dependency setup failed. $failures" \
    '{hookSpecificOutput: {hookEventName: $event, additionalContext: $msg}}'
fi
exit 0

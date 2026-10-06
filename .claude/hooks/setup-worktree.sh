#!/usr/bin/env bash
# SessionStart and SubagentStart hook: installs any missing Hex or JS
# dependencies in the checkout Claude starts in, so a new worktree can
# build and test before Claude's first turn. The hook input's `cwd` is
# that checkout; CLAUDE_PROJECT_DIR is the session's project, which for
# an `isolation: "worktree"` subagent is a different checkout.
#
# Mix deps count as missing when there is no deps/, or a mix.lock git dep
# has no deps/<name>/.git (the nested repo .worktreeinclude does not
# copy). mix.lock also lists optional deps that are never fetched, so
# other entries are not checked. JS deps count as missing when
# node_modules has no pnpm state.
# Nothing is printed when nothing is missing. A failed install is reported
# to Claude as additional context, never blocking the session.
set -uo pipefail

input=$(cat)
event=$(jq -r '.hook_event_name // empty' <<<"$input" 2>/dev/null)
cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null || exit 0
[ -f mix.lock ] && [ -f pnpm-lock.yaml ] || exit 0

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
  if ! "$@" >"$log" 2>&1; then
    failures+="\`$*\` failed in $cwd:"$'\n'"$(tail -n 20 "$log")"$'\n'
  fi
}

if mix_deps_missing; then run mix deps.get; fi
if [ ! -f node_modules/.modules.yaml ]; then
  run pnpm install --frozen-lockfile --prefer-offline
fi
rm -f "$log"

if [ -n "$failures" ]; then
  jq -n --arg event "$event" --arg msg "Dependency setup failed. $failures" \
    '{hookSpecificOutput: {hookEventName: $event, additionalContext: $msg}}'
fi
exit 0

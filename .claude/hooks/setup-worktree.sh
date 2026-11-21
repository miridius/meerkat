#!/usr/bin/env bash
# SessionStart, SubagentStart and PostToolUse(EnterWorktree) hook: runs
# this script's checkout's scripts/setup-worktree.ts with that checkout's
# Bun pin, which mise installs first when missing, or else with the Bun on
# PATH.
cd "$(dirname "$0")/../.." || exit 0
if command -v mise >/dev/null && mise install bun >/dev/null 2>&1; then
  PATH="$(mise where bun)/bin:$PATH"
fi
exec bun scripts/setup-worktree.ts

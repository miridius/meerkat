#!/usr/bin/env bash
# PreToolUse hook for mcp__claude-in-chrome__* tools: subagents must never
# drive the user's real Chrome (they use the Playwright MCP instead). Claude
# Code sets `agent_id` in the hook input only for calls made inside a
# subagent, so top-level sessions keep Chrome access. Fails closed: if the
# input cannot be parsed, the call is blocked.
set -uo pipefail

in_subagent=$(jq -r 'has("agent_id")' 2>/dev/null)
case "$in_subagent" in
  false) exit 0 ;;
  true) echo "Subagents may not use claude-in-chrome tools; use the mcp__playwright__* tools instead." >&2 ;;
  *) echo "deny-subagent-chrome: could not parse hook input (is jq installed?); blocking Chrome call." >&2 ;;
esac
exit 2

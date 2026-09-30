#!/usr/bin/env bash
# PreToolUse hook for Bash: caps a subagent's foreground command timeout at
# 270 s. A command that reaches its timeout moves to the background, so the
# subagent resumes before its 5-minute prompt cache expires. Claude Code sets
# `agent_id` in the hook input only for calls made inside a subagent, so
# top-level sessions are never capped. Calls with run_in_background keep
# their timeout, because there it is the background run limit. Fails open:
# on unparseable input it exits 1, a non-blocking error, and the call runs
# unchanged.
set -uo pipefail

jq -c '.tool_input as $in
  | if (has("agent_id") | not)
      or ($in.run_in_background // false)
      or (($in.timeout // infinite) <= 270000)
    then empty
    else {hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: ($in + {timeout: 270000})}}
    end' || exit 1

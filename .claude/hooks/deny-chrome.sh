#!/usr/bin/env bash
# PreToolUse hook for mcp__claude-in-chrome__* tools: no session, top-level
# or subagent, drives the user's own Chrome through claude-in-chrome;
# agents use headless Playwright instead.
echo "claude-in-chrome tools are blocked in meerkat; use headless Playwright instead." >&2
exit 2

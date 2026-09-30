#!/usr/bin/env bash
# Pre-commit hook: refuse commits made directly on `main`.
#
# Feature work, bug fixes, and anything else that'd merit a PR must land
# on a branch that goes through review — not on main. This check catches
# accidental direct-to-main commits (the usual failure mode: finishing a
# task without remembering to branch first).

set -euo pipefail

PROTECTED_BRANCH="main"

# Fail closed: if git itself can't tell us the branch, refuse the commit
# rather than letting it through silently. A corrupt or unusual git state
# is exactly when a surprise commit to main would be worst.
if ! current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null); then
  echo "ERROR: could not determine current branch — refusing commit." >&2
  echo "(Run \`git status\` to diagnose.)" >&2
  exit 1
fi

if [ "$current_branch" != "$PROTECTED_BRANCH" ]; then
  exit 0
fi

echo "ERROR: Direct commits to '$PROTECTED_BRANCH' are blocked." >&2
echo "Create a branch first:" >&2
echo "    git switch -c <branch-name>" >&2
echo "    git commit ..." >&2
exit 1

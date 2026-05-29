#!/bin/bash
set -e

cd "$(dirname "$0")/.."

BASE_BRANCH="${BASE_BRANCH:-main}"

# Pick the right diff for the context:
#   * pre-commit: there are staged changes → those ARE the impending commit.
#   * ad-hoc on a branch: no staged changes → fall back to branch-vs-main.
CHANGED_FILES=$(git diff --cached --name-only 2>/dev/null)
if [[ -z "$CHANGED_FILES" ]]; then
  CHANGED_FILES=$(git diff --name-only "origin/${BASE_BRANCH}...HEAD" 2>/dev/null || git diff --name-only "origin/${BASE_BRANCH}" 2>/dev/null || echo "")
fi

elixir_changed=false

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  case "$file" in
    assets/*|lib/*|config/*|test/*|mix.exs|mix.lock|.formatter.exs)
      elixir_changed=true
      ;;
  esac
done <<< "$CHANGED_FILES"

if [[ "$elixir_changed" == false ]]; then
  echo "No code files changed vs origin/${BASE_BRANCH} — skipping checks"
  exit 0
fi

echo "=== Phoenix-port checks ==="
echo "Running mix format --check-formatted..."
mix format --check-formatted

echo "Running mix compile --warnings-as-errors..."
mix compile --warnings-as-errors

echo "=== All checks passed ==="

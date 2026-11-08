#!/usr/bin/env bash
# Records which commit contents have passed scripts/check.sh, or with
# --mutated the mutation gate of scripts/mutate.sh, so the pre-push hook can
# tell whether a commit it is about to push was ever checked. A rebase
# or cherry-pick makes commits without running the pre-commit hook. With
# --e2e it records which contents passed check.sh's e2e steps, so a commit
# that skips them can count as checked when its e2e inputs already passed.
#
#   checked-trees.sh [--mutated|--e2e] mark <tree-ish>  record that its
#                                                       contents passed
#   checked-trees.sh [--mutated|--e2e] has <tree-ish>   exit 0 if its contents
#                                                       passed, else 1
#   checked-trees.sh holds <tree-ish>  exit 0 if the worktree holds exactly its
#                                      contents, with no untracked file, else 1
#
# Contents are keyed on every file except Markdown, which neither gate tests:
# a commit that changes only Markdown counts as checked when its parent was.
# The --e2e record is keyed on the e2e inputs scripts/e2e-inputs.ts picks.
# Marks live in the git common dir, so every worktree shares them.
set -euo pipefail

usage() {
  echo "usage: checked-trees.sh [--mutated|--e2e] mark|has|holds <tree-ish>" >&2
  exit 2
}

store=meerkat-checked
filter() { grep -v $'\t.*\\.md$' || true; }
case "${1:-}" in
--mutated)
  store=meerkat-mutated
  shift
  ;;
--e2e)
  store=meerkat-e2e
  filter() { bun "$(dirname "$0")/e2e-inputs.ts"; }
  shift
  ;;
esac

[[ $# -eq 2 ]] || usage

key() {
  git ls-tree -r --full-tree "$1^{tree}" | filter | git hash-object --stdin
}

dir="$(git rev-parse --path-format=absolute --git-common-dir)/$store"
k=$(key "$2")

case "$1" in
mark)
  mkdir -p "$dir"
  touch "$dir/$k"
  ;;
has)
  [[ -f "$dir/$k" ]]
  ;;
holds)
  # Unlike `git status`, neither command hides untracked files under
  # status.showUntrackedFiles=no, and a git error counts as not holding.
  git diff --quiet "$2^{tree}" --
  others=$(git ls-files --others --exclude-standard)
  [[ -z "$others" ]]
  ;;
*)
  usage
  ;;
esac

#!/usr/bin/env bash
# Records which commit contents have passed scripts/check.sh, so the pre-push
# hook can tell whether a commit it is about to push was ever checked. A rebase,
# merge or cherry-pick makes commits without running the pre-commit hook.
#
#   checked-trees.sh mark <tree-ish>   record that its contents passed
#   checked-trees.sh has <tree-ish>    exit 0 if its contents passed, else 1
#
# Contents are keyed on every file except Markdown, which check.sh skips: a
# commit that changes only Markdown counts as checked when its parent was.
# Marks live in the git common dir, so every worktree shares them.
set -euo pipefail

usage() {
  echo "usage: checked-trees.sh mark|has <tree-ish>" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage

key() {
  git ls-tree -r --full-tree "$1^{tree}" | { grep -v $'\t.*\\.md$' || true; } | git hash-object --stdin
}

dir="$(git rev-parse --path-format=absolute --git-common-dir)/meerkat-checked"
k=$(key "$2")

case "$1" in
mark)
  mkdir -p "$dir"
  touch "$dir/$k"
  ;;
has)
  [[ -f "$dir/$k" ]]
  ;;
*)
  usage
  ;;
esac

#!/usr/bin/env bash
# Pre-push hook: refuse to push any commit whose history does not start
# at this repo's public root commit.
#
# The repo was republished from a single fresh commit. History from
# before it is private: it names people, paths and places that must
# never be published, and a clone that still holds it can push it by
# naming an old branch. no-private-refs.sh refuses only the text it
# knows to look for, so this check refuses the old history itself:
# every commit pushed must descend from PUBLIC_ROOT and from no other
# root commit.
#
# It runs two ways:
#
#   - from .lefthook/pre-push/pre-push.sh, in every checkout whose tree
#     has it;
#   - as a config-based hook (`hook.publicroot.*`, git 2.54+) from a
#     copy in the git common dir, which `scripts/public-root.sh
#     --install` puts there and scripts/auto-install.sh refreshes
#     whenever main is checked out. Git runs it for every worktree of
#     the clone, alongside lefthook, whatever lefthook config the
#     worktree's branch carries and even with LEFTHOOK=0.
#
# Nothing runs it for `git push --no-verify`, for `git send-pack`, for
# a git too old for config-based hooks, or for content sent through
# GitHub's API.
#
# Reads Git's pre-push lines on stdin: local ref and SHA, then remote
# ref and SHA. `--root <sha>` names another root, for the tests. The
# installed hook is run as `--hook <remote> <url>`, so a remote's name
# can never be read as an option.

set -euo pipefail

# Judge the objects the push sends: pack-objects ignores replace refs
# and grafts, which could otherwise give old history a public parent.
export GIT_NO_REPLACE_OBJECTS=1
export GIT_GRAFT_FILE=/nonexistent/public-root-no-grafts

PUBLIC_ROOT=fb5bd7f852c92bd82e1a5011f1eb04309519ccff

if [ "${1:-}" = "--install" ]; then
  dest="$(git rev-parse --path-format=absolute --git-common-dir)/hooks/public-root.sh"
  mkdir -p "$(dirname "$dest")"
  cp "${BASH_SOURCE[0]}" "$dest"
  # The config is the clone's shared one, so every worktree sees it.
  git config --local hook.publicroot.command "$(printf 'bash %q --hook' "$dest")"
  git config --local --replace-all hook.publicroot.event pre-push
  if ! git hook list pre-push | grep -qx publicroot; then
    echo "public-root: Git will not run the pre-push hook publicroot (\`git hook list pre-push\` lacks it) — check hook.publicroot.enabled and that git is 2.54 or later." >&2
    exit 1
  fi
  echo "public-root: installed $dest as a pre-push hook for every worktree."
  exit 0
fi

root=$PUBLIC_ROOT
if [ "${1:-}" = "--root" ]; then
  root="$2"
fi

zero=0000000000000000000000000000000000000000
status=0
while read -r local_ref local_sha remote_ref _remote_sha; do
  # A zero local SHA deletes the remote ref and pushes nothing.
  [ "$local_sha" != "$zero" ] || continue
  if ! roots=$(git rev-list --max-parents=0 "$local_sha" --); then
    echo "public-root: cannot list the history of $local_ref — refusing the push." >&2
    status=1
    continue
  fi
  if [ "$roots" != "$root" ]; then
    echo "public-root: $local_ref would push history that does not start at the public root $root — refusing the push to $remote_ref." >&2
    found=${roots//$'\n'/ }
    echo "  Root commits found: ${found:-(none)}" >&2
    status=1
  fi
done

if [ "$status" -ne 0 ]; then
  echo "" >&2
  echo "History from before the public root is private and must never be pushed." >&2
  echo "Reproduce the change on a branch from origin/main instead." >&2
fi
exit "$status"

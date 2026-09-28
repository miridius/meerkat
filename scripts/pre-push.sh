#!/usr/bin/env bash
# This is the pre-push hook. Run both checks here because lefthook forwards Git's
# ref-list stdin only to a command configured with `use_stdin`, and this script
# needs that input.
# The checks are scripts/no-private-refs.sh and scripts/outdated.sh.
set -uo pipefail

cd "$(dirname "$0")/.."

zero=0000000000000000000000000000000000000000
pushes_commits=0
# Git provides one line per ref: local ref and SHA, then remote ref and SHA.
# A zero local SHA means deletion. `git push origin --delete <branch>` runs this
# hook too, but pushes no commits; outdated.sh can otherwise block deleting a
# merged branch when a dependency is behind its latest release or a registry is
# unreachable. Skip checks when every ref being pushed is a deletion.
while read -r _local_ref local_sha _remote_ref _remote_sha; do
  [ "$local_sha" = "$zero" ] || pushes_commits=1
done

if [ "$pushes_commits" = 0 ]; then
  echo "pre-push: only deleting remote refs; skipping checks."
  exit 0
fi

# Either failure blocks the push, but always run both checks so each can report
# its findings.
status=0
bash scripts/no-private-refs.sh || status=1
bash scripts/outdated.sh || status=1
exit "$status"

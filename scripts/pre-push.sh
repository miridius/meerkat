#!/usr/bin/env bash
# This is the pre-push hook. It runs scripts/no-private-refs.sh and
# scripts/outdated.sh. Both run from here because Git's list of pushed refs,
# which lefthook forwards only to a command configured with `use_stdin`, decides
# whether either runs, and no-private-refs.sh needs the pushed commits from it.
set -uo pipefail

cd "$(dirname "$0")/.."

zero=0000000000000000000000000000000000000000
pushed=()
refs=0
# Git provides one line per ref: local ref and SHA, then remote ref and SHA.
# A zero local SHA means deletion. `git push origin --delete <branch>` runs this
# hook too, but pushes no commits; outdated.sh can otherwise block deleting a
# merged branch when a dependency is behind its latest release or a registry is
# unreachable. Skip checks when every ref being pushed is a deletion.
while read -r _local_ref local_sha _remote_ref _remote_sha; do
  refs=$((refs + 1))
  [ "$local_sha" = "$zero" ] || pushed+=("$local_sha")
done

# Git also runs this hook, with no refs, for a push that has nothing to send.
if [ "${#pushed[@]}" = 0 ]; then
  [ "$refs" = 0 ] || echo "pre-push: only deleting remote refs; skipping checks."
  exit 0
fi

# Either failure blocks the push, but always run both checks so each can report
# its findings.
status=0
bash scripts/no-private-refs.sh "${pushed[@]}" || status=1
bash scripts/outdated.sh || status=1
exit "$status"

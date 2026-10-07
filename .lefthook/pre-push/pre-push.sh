#!/usr/bin/env bash
# This is the pre-push hook. It runs scripts/no-private-refs.sh,
# scripts/outdated.sh and scripts/verified-push.sh. They run from here because
# Git's list of pushed refs, which lefthook forwards through `use_stdin`,
# decides whether any runs. no-private-refs.sh needs the pushed refs and tips
# from it, and the URL pushed to, which Git passes as the second argument;
# verified-push.sh needs the tips.
#
# lefthook runs it as a script rather than a command: lefthook skips a
# pre-push command whenever `git diff HEAD @{push}` lists no files, which
# is the case for a force-push that only rewrites history, and would let
# rewritten commit messages out unscanned.
set -uo pipefail

cd "$(dirname "$0")/../.."

zero=0000000000000000000000000000000000000000
pushed=()
scan_args=(--remote "${2:-}")
refs=0
# Git provides one line per ref: local ref and SHA, then remote ref and SHA.
# A zero local SHA means deletion. `git push origin --delete <branch>` runs this
# hook too, but pushes no commits; outdated.sh can otherwise block deleting a
# merged branch when a dependency is behind its latest release or a registry is
# unreachable. Skip checks when every ref being pushed is a deletion.
while read -r _local_ref local_sha remote_ref _remote_sha; do
  refs=$((refs + 1))
  if [ "$local_sha" != "$zero" ]; then
    pushed+=("$local_sha")
    scan_args+=(--ref "$remote_ref" "$local_sha")
  fi
done

# Git also runs this hook, with no refs, for a push that has nothing to send.
if [ "${#pushed[@]}" = 0 ]; then
  [ "$refs" = 0 ] || echo "pre-push: only deleting remote refs; skipping checks."
  exit 0
fi

# Either failure blocks the push, but always run both checks so each can report
# its findings.
status=0
bash scripts/no-private-refs.sh "${scan_args[@]}" || status=1
bash scripts/outdated.sh || status=1

# verified-push.sh can run the whole pre-commit gate once per unchecked tip,
# which takes minutes each, so it runs only when the push would otherwise go
# through.
if [ "$status" = 0 ]; then
  bash scripts/verified-push.sh "${pushed[@]}" || status=1
fi
exit "$status"

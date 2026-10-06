# Sourced (POSIX sh) by every git hook lefthook installs, from the
# checkout's root, before it runs that checkout's lefthook: see
# lefthook.yml's `rc:`. A checkout without `pnpm install`, as in a fresh
# worktree, has no lefthook. There post-checkout and post-merge run
# their one script directly, a hook lefthook.yml does not configure
# (such as one only lefthook-local.yml adds) is skipped, and every other
# hook, pre-commit and pre-push included, is refused.
if [ -z "${LEFTHOOK_BIN-}" ] && [ ! -x node_modules/.bin/lefthook ]; then
  # Git hook names have no dot; a wrapper may run the shim as, say,
  # pre-commit.concise-orig.
  hook=${0##*/}
  hook=${hook%%.*}
  case "$hook" in
    post-checkout | post-merge) exec bash scripts/auto-install.sh ;;
  esac
  # Only grep's definite "no match" skips; an unreadable lefthook.yml refuses.
  grep -q "^$hook:" lefthook.yml
  if [ $? -eq 1 ]; then exit 0; fi
  echo "meerkat: lefthook is not installed in this checkout;" \
    "run \`mix deps.get && pnpm install\`." >&2
  exit 1
fi

# Sourced (POSIX sh) by every git hook lefthook installs, from the
# checkout's root, before it runs that checkout's lefthook: see
# lefthook.yml's `rc:`. A checkout without `pnpm install`, as in a fresh
# worktree, has no lefthook. The hooks lefthook.yml configures, such as
# pre-commit and pre-push, still refuse there, except that post-checkout
# and post-merge run their one script directly; any other hook, such as
# one only lefthook-local.yml adds, is skipped.
if [ ! -x node_modules/.bin/lefthook ]; then
  case "${0##*/}" in
    post-checkout | post-merge) exec bash scripts/auto-install.sh ;;
  esac
  grep -q "^${0##*/}:" lefthook.yml || exit 0
fi

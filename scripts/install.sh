#!/usr/bin/env bash
# Build + install meerkat for the current host. Produces a Mix
# release under ~/.local/share/meerkat-beam/release/ and wraps it in
# a launcher at ~/.local/bin/meerkat that forwards the user's cwd
# via $MEERKAT_PWD.
#
# Invoked automatically by the lefthook post-merge / post-checkout
# hooks (via scripts/auto-install.sh) whenever local `main` advances.
# Idempotent — skips the rebuild when the release is already built from
# the current commit. Run by hand any time via `bash scripts/install.sh`
# (or `--force` to rebuild even when unchanged).

set -euo pipefail

cd "$(dirname "$0")/.."

DEST_SHARE="${MEERKAT_INSTALL_PREFIX:-$HOME/.local/share/meerkat-beam}"
DEST_BIN="${MEERKAT_BIN_DIR:-$HOME/.local/bin}"
RELEASE_DIR="$DEST_SHARE/release"
WRAPPER="$DEST_BIN/meerkat"
INSTALLED_STAMP="$RELEASE_DIR/INSTALLED_COMMIT"

# Idempotency. The post-merge / post-checkout hooks fire this on every
# `main` checkout, but a rebuild takes minutes — so skip it when the
# installed release is already built from the current commit and the
# tree is clean. `--force` always rebuilds (to pick up uncommitted
# edits, or just to be sure). Substitutions use `|| true` so a non-repo
# / detached state can't trip `set -e`.
HEAD_COMMIT="$(git rev-parse HEAD 2>/dev/null || true)"
DIRTY="$(git status --porcelain 2>/dev/null || true)"
STAMPED="$(cat "$INSTALLED_STAMP" 2>/dev/null || true)"
if [[ "${1:-}" != "--force" && -n "$HEAD_COMMIT" && -x "$WRAPPER" \
      && -z "$DIRTY" && "$STAMPED" == "$HEAD_COMMIT" ]]; then
  echo "meerkat: release already built from ${HEAD_COMMIT:0:12} (clean tree) — skipping. Pass --force to rebuild."
  exit 0
fi

echo "meerkat: building Mix release for $(uname -sm)..."

# Fetch Elixir deps first: assets/package.json pulls phoenix /
# live_svelte / phoenix_vite JS out of deps/ via `file:` links, so
# deps/ must exist before `bun install` runs.
MIX_ENV=prod mix deps.get --only prod

# Phoenix assets need to be built before the release packages priv/.
if [[ -d assets ]]; then
  (cd assets && bun install --frozen-lockfile && bun run build)
fi

MIX_ENV=prod mix compile --warnings-as-errors
# Asset digest is mandatory for LiveView in prod — missing manifests
# = broken UI at runtime. Run loud + fail loud.
MIX_ENV=prod mix phx.digest
# Nuke the release dir before re-assembling so stale erts subdirs
# from prior builds (e.g. an old cross-platform release) can't
# shadow the current host's erts and break the launcher.
rm -rf _build/prod/rel
MIX_ENV=prod mix release --overwrite

SRC_RELEASE="_build/prod/rel/meerkat"
if [[ ! -x "$SRC_RELEASE/bin/meerkat" ]]; then
  echo "meerkat: release artefact missing at $SRC_RELEASE/bin/meerkat" >&2
  exit 1
fi

echo "meerkat: installing release to $RELEASE_DIR"
mkdir -p "$DEST_SHARE" "$DEST_BIN"
# Stage to a sibling dir + atomic-rename so a running meerkat
# instance keeps reading the old release files (BEAM lazy-loads
# .beam modules + reads `releases/<vsn>/sys.config` on demand). The
# replaced directory is removed via `mv` swap rather than `rm -rf`
# under a live BEAM.
STAGING_DIR="$DEST_SHARE/release.new.$$"
rm -rf "$STAGING_DIR"
cp -R "$SRC_RELEASE" "$STAGING_DIR"
if [[ -d "$RELEASE_DIR" ]]; then
  OLD_DIR="$DEST_SHARE/release.old.$$"
  mv "$RELEASE_DIR" "$OLD_DIR"
fi
mv "$STAGING_DIR" "$RELEASE_DIR"
[[ -n "${OLD_DIR:-}" ]] && rm -rf "$OLD_DIR"

# `RELEASE_DIR` is baked in below (not hardcoded to $HOME) so a custom
# MEERKAT_INSTALL_PREFIX is honored end-to-end. printf %q keeps the
# path safe if it contains spaces.
{
  echo '#!/usr/bin/env bash'
  cat <<'WRAPPER_EOF'
# meerkat launcher (installed by scripts/install.sh).
# Forwards the user's cwd as $MEERKAT_PWD so the release can target
# the right git repo regardless of where the release was built.
# `bin/meerkat eval EXPR ARGS…` passes ARGS verbatim as System.argv
# inside the eval'd expression; do NOT use `--` separator (the
# release passes that through to argv as a literal "--" entry).
set -euo pipefail
export MEERKAT_PWD="${MEERKAT_PWD:-$PWD}"
WRAPPER_EOF
  printf 'RELEASE_DIR=%q\n' "$RELEASE_DIR"
  cat <<'WRAPPER_EOF'
if [[ ! -x "$RELEASE_DIR/bin/meerkat" ]]; then
  echo "meerkat: release missing at $RELEASE_DIR/bin/meerkat — re-run scripts/install.sh from the meerkat repo." >&2
  exit 127
fi
exec "$RELEASE_DIR/bin/meerkat" eval "Meerkat.CLI.main(System.argv()) |> System.halt()" "$@"
WRAPPER_EOF
} > "$WRAPPER"
chmod +x "$WRAPPER"

echo "meerkat: installed $WRAPPER -> $RELEASE_DIR/bin/meerkat"

# Real smoke test: an empty-staged-no-commit-msg invocation hits the
# `:auto, "no staged file changes — auto-approving"` fast path (cli.ex
# auto_approve_decision/2 staged-empty branch). Exits 0 without
# binding any port, proves the wrapper boots end-to-end. Stream
# stdout/stderr so failures surface; non-zero exit aborts install.
echo "meerkat: smoke-testing launcher in a throwaway repo..."
SMOKE_DIR="$(mktemp -d -t meerkat-smoke.XXXXXX)"
trap 'rm -rf "$SMOKE_DIR"' EXIT
(
  # When this script is invoked from the lefthook post-merge hook,
  # GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE etc are set to the
  # *parent* meerkat repo. Without unsetting them, the smoke test's
  # `git init` re-initialises the parent repo, and `git commit
  # --allow-empty -m init` lands a phantom "init" commit on the
  # caller's local branch. Strip every `GIT_*` env var before
  # touching the throwaway repo.
  unset $(env | awk -F= '/^GIT_/ {print $1}')
  cd "$SMOKE_DIR"
  git init -q -b main
  git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  echo "msg" > MSG
  MEERKAT_PWD="$SMOKE_DIR" "$WRAPPER" --commit-msg MSG --no-open
)
# Stamp the installed commit so the next hook-triggered run can skip the
# rebuild when nothing changed (see the idempotency guard at the top).
if [[ -n "$HEAD_COMMIT" ]]; then
  printf '%s\n' "$HEAD_COMMIT" > "$INSTALLED_STAMP"
fi

echo "meerkat: done."

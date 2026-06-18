#!/usr/bin/env bash
# Build + install meerkat for the current host. Produces a Mix release
# under ~/.local/share/meerkat-beam/versions/<id>/ and points a
# ~/.local/share/meerkat-beam/current symlink at it, wrapped by a
# launcher at ~/.local/bin/meerkat that forwards the user's cwd via
# $MEERKAT_PWD.
#
# Versioned + symlinked so an upgrade never disturbs a running review:
# each build lands in its own immutable `versions/<id>` dir, the
# launcher resolves `current` to a concrete version AT LAUNCH, and a
# new install flips the symlink without touching the dir a live BEAM is
# reading. Old version dirs are GC'd (keep the newest few + any a
# running review is still pinned to).
#
# Invoked automatically by the lefthook post-merge / post-checkout
# hooks (via scripts/auto-install.sh) whenever local `main` advances.
# Idempotent: skips the rebuild when `current` already points at this
# commit's version and the tree is clean. Run by hand any time via
# `bash scripts/install.sh` (or `--force` to rebuild even when
# unchanged).

set -euo pipefail

cd "$(dirname "$0")/.."

DEST_SHARE="${MEERKAT_INSTALL_PREFIX:-$HOME/.local/share/meerkat-beam}"
DEST_BIN="${MEERKAT_BIN_DIR:-$HOME/.local/bin}"
VERSIONS_DIR="$DEST_SHARE/versions"
CURRENT_LINK="$DEST_SHARE/current"
WRAPPER="$DEST_BIN/meerkat"
# How many version dirs to retain for rollback/history. A version a
# running review is still pinned to is always kept, even past this.
KEEP_VERSIONS=5

HEAD_COMMIT="$(git rev-parse HEAD 2>/dev/null || true)"
DIRTY="$(git status --porcelain 2>/dev/null || true)"

# Version id: the commit for a clean build (so re-running the same
# commit is a no-op), with a timestamp suffix for a dirty/forced build
# so it can't collide with (or overwrite) the clean commit's dir.
if [[ -n "$HEAD_COMMIT" && -z "$DIRTY" ]]; then
  VERSION_ID="${HEAD_COMMIT:0:12}"
else
  VERSION_ID="${HEAD_COMMIT:0:12}-wip.$(date +%s)"
fi

# True when any running process is reading $1 (a version dir): the BEAM
# references it as `<dir>/...` (bindir, boot_var RELEASE_LIB, …), so the
# match is anchored on a trailing slash. Without it a clean-commit id is
# a substring of its own `<id>-wip.<ts>` sibling and they cross-match.
# Keeps GC from deleting a dir a live review still lazy-loads from. The
# `ps` output is captured and matched with a bash builtin, not piped to
# `grep "$1"`: a grep carrying the path matches its own command line in
# `ps` and every dir would look in-use.
dir_in_use() {
  local cmds
  cmds="$(ps -axo command= 2>/dev/null || true)"
  [[ "$cmds" == *"$1/"* ]]
}

# Idempotency: the post-merge / post-checkout hooks fire this on every
# `main` checkout, but a rebuild takes minutes, so skip when `current`
# already resolves to this commit's version and the tree is clean.
CURRENT_TARGET="$(readlink "$CURRENT_LINK" 2>/dev/null || true)"
if [[ "${1:-}" != "--force" && -n "$HEAD_COMMIT" && -z "$DIRTY" && -x "$WRAPPER" \
      && "$(basename "$CURRENT_TARGET" 2>/dev/null)" == "$VERSION_ID" \
      && -x "$CURRENT_TARGET/bin/meerkat" ]]; then
  echo "meerkat: current already built from ${HEAD_COMMIT:0:12} (clean tree); skipping. Pass --force to rebuild."
  exit 0
fi

echo "meerkat: building Mix release for $(uname -sm)..."

# Fetch Elixir deps first: assets/package.json pulls phoenix /
# live_svelte / phoenix_vite JS out of deps/ via `file:` links, so
# deps/ must exist before `pnpm install` runs.
MIX_ENV=prod mix deps.get --only prod

# Phoenix assets need to be built before the release packages priv/.
# pnpm installs (the workspace covers assets/ too); bun runs the
# build; see pnpm-workspace.yaml for why the tools are split.
if [[ -d assets ]]; then
  pnpm install --frozen-lockfile --ignore-scripts
  (cd assets && bun run build)
fi

MIX_ENV=prod mix compile --warnings-as-errors
# Asset digest is mandatory for LiveView in prod: missing manifests
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

mkdir -p "$VERSIONS_DIR" "$DEST_BIN"

# Stage the new version beside its final home, then atomic-rename it
# in. A version dir a running review is pinned to is immutable: if this
# id already exists and is in use (a forced rebuild of the same
# commit), pick a fresh suffixed id rather than clobber it.
FINAL_DIR="$VERSIONS_DIR/$VERSION_ID"
if [[ -e "$FINAL_DIR" ]] && dir_in_use "$FINAL_DIR"; then
  VERSION_ID="$VERSION_ID-$(date +%s)"
  FINAL_DIR="$VERSIONS_DIR/$VERSION_ID"
fi
STAGING_DIR="$VERSIONS_DIR/.staging.$$"
rm -rf "$STAGING_DIR"
cp -R "$SRC_RELEASE" "$STAGING_DIR"
rm -rf "$FINAL_DIR"
mv "$STAGING_DIR" "$FINAL_DIR"
echo "meerkat: built version $VERSION_ID at $FINAL_DIR"

# Smoke-test the new release BEFORE flipping `current` at it: an
# empty-staged-no-commit-msg invocation hits the auto-approve fast path
# (cli.ex auto_approve_decision/2 staged-empty branch), exits 0 without
# binding a port, and proves the release boots end-to-end. Gating the
# flip on it means a build that fails its smoke test leaves `current` on
# the last good version and the next hook run rebuilds, instead of
# activating a broken release that the idempotency check would then skip.
echo "meerkat: smoke-testing the new release in a throwaway repo..."
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
  # Invoke the new version's launcher exactly as the wrapper does, but
  # against $FINAL_DIR directly, since `current` isn't pointed at it yet.
  MEERKAT_PWD="$SMOKE_DIR" "$FINAL_DIR/bin/meerkat" \
    eval "Meerkat.CLI.main(System.argv()) |> System.halt()" --commit-msg MSG --no-open
)

# Flip `current` at the smoke-tested version. `mv -h` so the rename
# replaces the `current` symlink itself; plain `mv` follows a
# symlink-to-dir target and drops the temp link inside the old version
# dir (BSD semantics), silently leaving `current` unchanged. Absolute
# target so `readlink current` resolves standalone.
TMP_LINK="$CURRENT_LINK.tmp.$$"
ln -sfn "$FINAL_DIR" "$TMP_LINK"
mv -hf "$TMP_LINK" "$CURRENT_LINK"

# The launcher resolves `current` to a concrete version dir at launch
# and execs that, so each running review is pinned to its version for
# code + assets, and a later flip of `current` can't pull them out from
# under it. RELEASE_DIR is baked in (not hardcoded to $HOME) so a custom
# MEERKAT_INSTALL_PREFIX is honored end-to-end; printf %q keeps paths
# safe if they contain spaces.
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
  printf 'CURRENT_LINK=%q\n' "$CURRENT_LINK"
  cat <<'WRAPPER_EOF'
RELEASE_DIR="$(readlink "$CURRENT_LINK" 2>/dev/null || true)"
if [[ -z "$RELEASE_DIR" || ! -x "$RELEASE_DIR/bin/meerkat" ]]; then
  echo "meerkat: no current release at $CURRENT_LINK; re-run scripts/install.sh from the meerkat repo." >&2
  exit 127
fi
exec "$RELEASE_DIR/bin/meerkat" eval "Meerkat.CLI.main(System.argv()) |> System.halt()" "$@"
WRAPPER_EOF
} > "$WRAPPER"
chmod +x "$WRAPPER"

echo "meerkat: installed $WRAPPER -> $CURRENT_LINK"

# GC old versions: keep the newest $KEEP_VERSIONS (by mtime), the
# `current` target, and any dir a running review is still pinned to;
# delete the rest. Also retire the pre-versioning `release/` dir once no
# live BEAM is reading it (migration cleanup).
current_target="$(readlink "$CURRENT_LINK" 2>/dev/null || true)"
kept=0
while IFS= read -r v; do
  v="${v%/}"
  [[ -z "$v" || "$v" == "$FINAL_DIR" || "$v" == "$current_target" ]] && continue
  kept=$((kept + 1))
  if [[ "$kept" -le "$KEEP_VERSIONS" ]]; then
    continue
  fi
  if dir_in_use "$v"; then
    continue
  fi
  rm -rf "$v"
done < <(ls -1dt "$VERSIONS_DIR"/*/ 2>/dev/null)

LEGACY_RELEASE="$DEST_SHARE/release"
if [[ -d "$LEGACY_RELEASE" ]] && ! dir_in_use "$LEGACY_RELEASE"; then
  rm -rf "$LEGACY_RELEASE"
fi

echo "meerkat: done."

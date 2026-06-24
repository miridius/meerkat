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
# The prod shepherd lives outside the version dirs (it re-resolves
# `current` every spawn, so it's version-agnostic and survives GC).
SHEPHERD_DEST="$DEST_SHARE/meerkat-shepherd"
# How many version dirs to retain for rollback/history. A version a
# running review is still pinned to is always kept, even past this.
KEEP_VERSIONS=5

HEAD_COMMIT="$(git rev-parse HEAD 2>/dev/null || true)"
DIRTY="$(git status --porcelain 2>/dev/null || true)"

# Version id (a human-readable dir name; uniqueness is enforced later by
# the build loop): the commit for a clean build, marked `-wip.<ts>` when
# built from a dirty tree so it reads as "not a pristine commit build".
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

# Bake a version manifest into the release so the toolbar chip can show
# what version is running and the recent changelog. Plain newline format
# (commit, repo URL, then the last 15 first-parent subjects verbatim) so
# no JSON escaping is needed in bash; Meerkat.Version parses the `(#N)`
# out of each subject. First-parent on `main` is one squashed commit per
# merged PR.
write_version_manifest() {
  local out="$1" repo_url
  repo_url="$(git config --get remote.origin.url 2>/dev/null |
    sed -E 's#^git@github\.com:#https://github.com/#; s#\.git$##' || true)"
  {
    printf '%s\n' "$HEAD_COMMIT"
    printf '%s\n' "$repo_url"
    git log --first-parent --format='%s' -n 15 "$HEAD_COMMIT" 2>/dev/null || true
  } > "$out"
}

# Idempotency: the post-merge / post-checkout hooks fire this on every
# `main` checkout, but a rebuild takes minutes, so skip when `current`
# is already a clean build of this commit. Keyed on the commit stamp in
# the current version dir, not its name, so a forced rebuild can land in
# a fresh immutable dir without making every later run rebuild.
CURRENT_TARGET="$(readlink "$CURRENT_LINK" 2>/dev/null || true)"
CURRENT_STAMP="$(cat "$CURRENT_TARGET/INSTALLED_COMMIT" 2>/dev/null || true)"
if [[ "${1:-}" != "--force" && -n "$HEAD_COMMIT" && -z "$DIRTY" && -x "$WRAPPER" \
      && "$CURRENT_STAMP" == "$HEAD_COMMIT" \
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

# A version dir is immutable once built: a running review lazy-loads
# code/assets from it for its whole life. So never build over an
# existing dir (a `--force` rebuild of a commit that's already `current`
# would otherwise rm it out from under a review that resolved `current`
# to it mid-rebuild); take the first free `<id>` / `<id>.N` instead.
FINAL_DIR="$VERSIONS_DIR/$VERSION_ID"
n=1
while [[ -e "$FINAL_DIR" ]]; do
  FINAL_DIR="$VERSIONS_DIR/$VERSION_ID.$n"
  n=$((n + 1))
done
VERSION_ID="$(basename "$FINAL_DIR")"

# Stamp the source commit so the idempotency check can tell whether
# `current` is already this commit, independent of the dir name.
printf '%s\n' "$HEAD_COMMIT" > "$SRC_RELEASE/INSTALLED_COMMIT"
write_version_manifest "$SRC_RELEASE/meerkat_version"

# Stage beside the final home, then atomic-rename into place.
STAGING_DIR="$VERSIONS_DIR/.staging.$$"
rm -rf "$STAGING_DIR"
cp -R "$SRC_RELEASE" "$STAGING_DIR"
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

# Install the shepherd via temp + atomic rename: a shepherd a review is
# already running keeps its old inode (bash reads the script by offset
# as it loops), so replacing the path can't corrupt it mid-review.
cp bin/meerkat-shepherd "$SHEPHERD_DEST.tmp.$$"
chmod +x "$SHEPHERD_DEST.tmp.$$"
mv -f "$SHEPHERD_DEST.tmp.$$" "$SHEPHERD_DEST"

# The launcher is thin: it execs the shepherd, which loops the release
# BEAM, resolving `current` to a concrete version dir on each spawn so a
# review can live-restart onto a new version. The paths are baked in
# (not hardcoded to $HOME) so a custom MEERKAT_INSTALL_PREFIX is honored
# end-to-end; printf %q keeps them safe if they contain spaces.
{
  echo '#!/usr/bin/env bash'
  cat <<'WRAPPER_EOF'
# meerkat launcher (installed by scripts/install.sh). Forwards the
# user's cwd as $MEERKAT_PWD and hands off to the shepherd.
set -euo pipefail
export MEERKAT_PWD="${MEERKAT_PWD:-$PWD}"
WRAPPER_EOF
  printf 'export MEERKAT_CURRENT_LINK=%q\n' "$CURRENT_LINK"
  printf 'SHEPHERD=%q\n' "$SHEPHERD_DEST"
  cat <<'WRAPPER_EOF'
if [[ ! -x "$SHEPHERD" ]]; then
  echo "meerkat: shepherd missing at $SHEPHERD; re-run scripts/install.sh from the meerkat repo." >&2
  exit 127
fi
exec "$SHEPHERD" "$@"
WRAPPER_EOF
} > "$WRAPPER"
chmod +x "$WRAPPER"

echo "meerkat: installed $WRAPPER -> $SHEPHERD_DEST -> $CURRENT_LINK"

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

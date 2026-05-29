#!/usr/bin/env bash
# Install a DEV launcher at ~/.local/bin/meerkat that runs
# `bin/meerkat-beam` from THIS checkout with `MIX_ENV=dev`. Every
# `meerkat` invocation from any repo boots a BEAM whose code is read
# directly from this tree. `lib/` edits trigger a DevWatcher-driven
# BEAM restart on the same port; `assets/` edits need a fresh
# meerkat boot so `bin/meerkat-beam` rebuilds via `vite build`.
#
# Branch-only by design. The launcher's only purpose is fast
# iteration on UNMERGED work; merging to main always installs the
# prod release via `scripts/install.sh` (run from the lefthook
# post-merge hook). Refuses to run when HEAD is `main` — there's
# no point installing a dev launcher pointing at the same code a
# prod install would build from.
#
# Revert to prod: run `scripts/install.sh` from any meerkat
# checkout. Or merge work to main; the post-merge hook fires
# install.sh automatically.

set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$(pwd)"

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo)"
if [[ "$branch" == "main" ]]; then
  echo "scripts/dev-install.sh: refusing to install on main — dev mode is for unmerged work." >&2
  echo "Check out a feature branch first, or use scripts/install.sh for prod." >&2
  exit 2
fi

DEST_BIN="${MEERKAT_BIN_DIR:-$HOME/.local/bin}"
WRAPPER="$DEST_BIN/meerkat"

mkdir -p "$DEST_BIN"

cat > "$WRAPPER" <<WRAPPER_EOF
#!/usr/bin/env bash
# meerkat dev launcher (installed by scripts/dev-install.sh on
# branch '$branch' from $REPO).
# Runs $REPO/bin/meerkat-beam with MIX_ENV=dev so every invocation
# from any repo shares the same hot-reloadable BEAM image.
# Revert to prod via $REPO/scripts/install.sh (or merge to main).
set -euo pipefail
export MIX_ENV=dev
exec "$REPO/bin/meerkat-beam" "\$@"
WRAPPER_EOF
chmod +x "$WRAPPER"

echo "meerkat: dev launcher installed at $WRAPPER"
echo "         → $REPO/bin/meerkat-beam (branch '$branch')"
echo "meerkat: lib/ edits → DevWatcher restarts the running BEAM on"
echo "         the next file save. assets/ edits → restart meerkat to"
echo "         re-run vite build."
echo "meerkat: revert to prod with $REPO/scripts/install.sh"

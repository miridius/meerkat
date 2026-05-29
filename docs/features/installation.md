# Installation modes

`~/.local/bin/meerkat` is the public entrypoint. Two install
modes share that path:

1. **Dev launcher** — a thin shell script that `exec`s
   `bin/meerkat-beam` in this worktree under `MIX_ENV=dev`.
   Installed via `scripts/dev-install.sh`. Refuses to install
   from `main`; the branch's worktree is the source-of-truth for
   every meerkat invocation from any repo.
2. **Prod release** — `mix release` artefacts. Installed via
   `scripts/install.sh`. Self-contained; the worktree the script
   was run from is no longer relevant after install.

Only one mode active at a time. The launcher script content IS
the mode marker — re-running either script overwrites the other.

## Dev install

```
scripts/dev-install.sh
```

- Verifies the current HEAD is NOT `main`. Refuses otherwise.
- Writes a tiny `~/.local/bin/meerkat` that exports
  `MIX_ENV=dev` and `exec`s the `bin/meerkat-beam` shepherd in
  this worktree.
- Every subsequent `meerkat` invocation (from any cwd) routes
  through that shepherd → DevWatcher / hot reload / restart-on-
  source-change behaviour active.

Iterating on the UI:

- Edit `lib/meerkat/*.ex` / `lib/meerkat_web/**/*.ex` →
  DevWatcher fires → BEAM halts(75) → shepherd respawns on the
  same port → LV auto-reconnects.
- Edit `assets/svelte/*.svelte` / `assets/css/*.css` →
  DevWatcher fires → shepherd's `build_assets_if_stale` runs
  Vite → BEAM restarts → new assets serve. No HMR (Vite HMR is
  intentionally off in dev because LV's static-manifest
  cache-busting plays badly with it).

## Prod install

```
scripts/install.sh
```

- Builds a `mix release` under `_build/<env>/rel/meerkat`.
- Copies it to `~/.local/share/meerkat-beam/` (override via
  `MEERKAT_INSTALL_PREFIX`).
- Writes `~/.local/bin/meerkat` to launch the release directly,
  no Mix, no shepherd, no DevWatcher.

The post-merge git hook (`scripts/no-main-commits.sh` enables
lefthook, which runs `scripts/install.sh` on merge to `main`)
auto-installs prod whenever a feature branch lands. So a
`bundled-fixes → main` merge gives every consumer the prod
release without manual steps.

## Reverting between modes

- `scripts/install.sh` from any branch overwrites the dev
  launcher with the prod release.
- `scripts/dev-install.sh` from a non-main branch overwrites the
  prod launcher with the dev shell shim.

No marker file; the launcher script content IS the mode. Cat
`~/.local/bin/meerkat` to see which is active.

## Env vars

- `MEERKAT_BIN` — used by the e2e suite to point at the binary
  under test (defaults to whatever's on PATH).
- `MEERKAT_INSTALL_PREFIX` — release directory location (default
  `~/.local/share/meerkat-beam`).
- `MEERKAT_BIN_DIR` — launcher destination directory (default
  `~/.local/bin`).
- `MEERKAT_PWD` — set by the launcher to the caller's cwd, so
  the BEAM reads git state from the user's repo, not the worktree
  the launcher lives in.
- `MEERKAT_PORT` — override the deterministic port computation
  for tests / debugging.

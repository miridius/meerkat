# Installation

`~/.local/bin/meerkat` is the public entrypoint. `scripts/install.sh`
installs the prod release there.

`bin/meerkat-beam`, the dev launcher, runs meerkat from a checkout
under `MIX_ENV=dev`, compiling and building assets first when they are
stale. It runs `mix compile` when a source is newer than the build or
the launcher last compiled it in another checkout, so a build copied
into a new worktree never stands in for that worktree's sources. The e2e suite and agents verifying a change run it directly;
nothing installs it.

## Prod install

```
scripts/install.sh
```

- Builds a `mix release` under `_build/<env>/rel/meerkat`.
- Copies it to `~/.local/share/meerkat-beam/` (override via
  `MEERKAT_INSTALL_PREFIX`).
- Installs the prod shepherd `meerkat-shepherd`, and the
  `meerkat-attach` library it sources, beside the versions.
- Writes `~/.local/bin/meerkat` to exec that shepherd, which runs
  the release: no Mix. It replaces any other launcher there.

The post-merge git hook (`scripts/no-main-commits.ts` enables
lefthook, which runs `scripts/install.sh` on merge to `main`)
auto-installs prod whenever a feature branch lands. So a
`bundled-fixes → main` merge gives every consumer the prod
release without manual steps.

## Restart onto a new version

`Meerkat.VersionWatcher` notices a newly installed version, and the
BEAM halts with exit 75 at a safe point; the shepherd respawns it on
the new version, preferring the port the old BEAM bound. Phoenix
LiveView's client auto-reconnects. The tab stays put because the
shepherd keeps one secret across BEAMs, so its LiveView session token
remains valid. The socket reads no session cookie, so another review
loaded in the same browser, which replaces the cookie, doesn't stop
the rejoin. If the new build changed the assets' hashed names,
`ReviewLive.mount/3` instead redirects the reconnecting tab to "/" for
a full page load of the new build. The page's asset tags and that
check both use the manifest the BEAM read at boot. State survives
either way because:

- Comments + approvals are persisted to
  `<gitdir>/meerkat-precommit/in-progress/<review_id>.json` and
  reloaded by `ReviewServer.init/1`.
- Open forms are persisted in `ReviewState.open_forms`. After
  reconnect, `ReviewLive.mount/3` re-assigns them and `DiffViewer`
  injects each inline form at its anchor. Prose typed into an add
  form is kept in `localStorage` under
  `meerkat:draft:<review_id>:` followed by the form's key, which
  encodes its surface, anchor and edit target; reopening that form
  restores the draft. Edit forms ignore drafts and reopen with the
  saved comment's body.

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
- `MEERKAT_PORT` — when set and no explicit `--port` is supplied, the
  launcher copies this to `MEERKAT_PREFERRED_PORT` instead of using
  the stable review port. Intended for tests/debugging; invalid
  values are reported by the CLI as an invalid preferred port.
- `MEERKAT_RUNS_DIR` — where review backends keep their run dirs
  (default `${XDG_STATE_HOME:-~/.local/state}/meerkat/runs`). The e2e
  runner gives each test its own. The default is outside `$TMPDIR`
  because macOS deletes files there that are more than three days
  old, which would strand a review left waiting that long.
- `MEERKAT_CONFIG_DIR` — meerkat's config dir, which holds
  `settings.json` (default `meerkat` under `XDG_CONFIG_HOME` when that
  is absolute, else `~/.config/meerkat`). Taken only when it is an
  absolute path. Intended for tests, to keep a run's settings apart
  without changing the `XDG_CONFIG_HOME` that git reads.

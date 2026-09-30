# Dev mode

Installed via `scripts/dev-install.sh`. Writes
`~/.local/bin/meerkat` as a thin shell launcher that `exec`s
`bin/meerkat-beam` in the worktree with `MIX_ENV=dev`. The
production install (via `scripts/install.sh` or auto-installed on
merge to main) is replaced — only one or the other at a time.

Dev mode refuses to install from the `main` branch
(`scripts/dev-install.sh` exits non-zero if `git rev-parse
--abbrev-ref HEAD` returns `main`). The reasoning: hot-reload-on-
edit only makes sense when iterating on a branch.

## Hot reload

Two halves:

1. **`Meerkat.DevWatcher`** — a GenServer started by the
   application supervisor only when `MIX_ENV=dev`. It uses the
   `file_system` library to watch `lib/`, `assets/css`,
   `assets/svelte`, `assets/js`, `assets/ts`, and `config/`. On
   any meaningful event (created / modified / renamed / removed /
   moved) for a watched extension (`.ex`, `.exs`, `.heex`,
   `.svelte`, `.css`, `.js`, `.ts`, `.mjs`, `.cjs`), it debounces
   for 150ms and then `System.halt(75)`.

2. **`bin/meerkat-beam` shepherd loop** — the bash wrapper around
   `mix run --no-start --no-compile`. Exit code 75 means "restart".
   Before each respawn, the shepherd reads the exiting BEAM's
   `<port> <pid>` file and sets `MEERKAT_PREFERRED_PORT` to that port;
   a default-port or `--port 0` run therefore tries its last bound port
   first, so the browser's LiveView can reconnect. Any other
   non-zero exit in `MIX_ENV=dev` is also treated as "stay alive"
   — the shepherd blocks on `find -newer` waiting for the next
   source change and retries. Crash loops are bounded by the file-
   change wait; CPU stays idle.

Phoenix LiveView's client auto-reconnects when the BEAM dies on
exit 75. The browser tab stays put. State survives because:

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

## Deterministic port

The launcher always passes the arguments through unchanged. When no
`--port` is supplied, it sets `MEERKAT_PREFERRED_PORT` to
`MEERKAT_PORT` if set, or to the review's stable port:

`int(shasum256(cwd:args)[:8]) % 20000 + 40000`

The stable port means a fresh invocation of the same review from the
same repo reuses its port, keeping an open browser tab working without
re-navigation. The 40000–59999 range is above privileged ports; ports
below 49152 are outside macOS's default ephemeral range
(49152–65535), so collisions with OS-assigned ports are rare.
`MEERKAT_PORT` replaces the hash only when no `--port` is supplied
(useful for tests/debugging).

With no `--port`, the CLI defaults to port 0 and tries a valid
`MEERKAT_PREFERRED_PORT` (an integer from 1 to 65535). If that port is
in use, the CLI binds an OS-assigned port, then prints
`meerkat: port <N> is in use; serving on <url>` to stderr, where
`<url>` is the full review URL (for example `http://127.0.0.1:54563/`).
An invalid preferred-port value is ignored;
without a valid preference, port 0 is OS-assigned.

An explicit `--port N` or `--port=N` is passed through unchanged and
does not set an initial preferred port. `--port 0` requests an
OS-assigned port; an explicit nonzero port binds exactly that port and
fails to start if it is in use. After every BEAM exit, the shepherd
sets `MEERKAT_PREFERRED_PORT` from its `$MEERKAT_SERVE_DIR/port` file
(`<port> <pid>`) for the next run. With the default port or explicit
`--port 0`, a respawn tries the last bound port first so the browser's
LiveView can reconnect. If that preferred port is now in use, the CLI
warns and falls back to an OS-assigned port.

## What dev mode does NOT do

- Does not install on `main`. Merge → re-runs `scripts/install.sh`
  which overwrites the dev launcher with the prod release.
- Does not skip the safety try/rescue in CLI main. A crash still
  exits non-zero; in dev the shepherd just doesn't propagate.
- Does not change the LV's view of the world — the dev BEAM and
  the prod release-installed BEAM render identically. The only
  difference is the watch-and-restart loop on the outside.

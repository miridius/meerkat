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
   `mix run --no-start --no-compile`. Exit code 75 restarts after a
   code change; after every BEAM exit, the loop reads the run dir's
   `port` file, sets `MEERKAT_PREFERRED_PORT` to its port for the next
   BEAM, and deletes the file. With the default port or `--port 0`,
   the next BEAM tries that port first and falls back to an
   OS-assigned port if it is occupied; an explicit nonzero port is
   bound again. Any other exit is propagated, including crash exit 2.
   After a failed compile or asset build, the shepherd waits for a
   source change before retrying; if the checkout or review directory
   is deleted while it waits, it exits 2 with a REJECT message.

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

## Preferred port

With no explicit `--port N` or `--port=N`, both launchers discard any
inherited `MEERKAT_PREFERRED_PORT` and set it to `MEERKAT_PORT` if
nonempty, or to the review's stable port:
`int(shasum256(cwd:args)[:8]) % 20000 + 40000`. The CLI's `--port`
defaults to `0`; with port `0`, it tries a valid preferred port first.

Absent a `MEERKAT_PORT` override, a fresh invocation of the same review
(same repo and args) that starts a new server uses the same port when
available, so a browser tab left open on that port needs no
re-navigation. The 40000–59999 range is above privileged ports; its
portion below 49152 is outside macOS's default ephemeral range
(49152–65535), so OS-assigned port collisions are rare. `MEERKAT_PORT`
exists for tests and debugging.

If the preferred port is occupied, the CLI binds an OS-assigned port
and prints `meerkat: port <N> is in use; serving on <url>` to stderr,
with the full review URL (for example, `http://127.0.0.1:54563/`).
A preferred value must be an integer from 1 to 65535; otherwise the
CLI prints `meerkat: ignoring MEERKAT_PREFERRED_PORT="<value>": not a
port from 1 to 65535` to stderr and uses an OS-assigned port.

An explicit `--port N` or `--port=N` reaches the CLI unchanged. On the
initial BEAM, the launcher sets no preferred port and ignores
`MEERKAT_PORT`; explicit `--port 0` therefore requests an OS-assigned
port. A nonzero `N` binds exactly `N`; if occupied, the CLI prints
`meerkat: port N is in use (--port N); pick another port or omit
--port` and exits `64`.

After every BEAM exit, the launcher reads the run dir's `port` file
(`<port> <BEAM pid>`), sets `MEERKAT_PREFERRED_PORT` to that port for
the next BEAM, and immediately deletes the file. With the default port
or `--port 0`, the next BEAM tries that port first; if it is occupied,
the CLI falls back to an OS-assigned port. An explicit nonzero port is
bound again. Removing the file prevents callers from attaching to the
exited BEAM while the next one starts; a rerun while a server is alive
attaches to the port in its run dir's `port` file rather than binding
another.

## What dev mode does NOT do

- Does not install on `main`. Merge → re-runs `scripts/install.sh`
  which overwrites the dev launcher with the prod release.
- Does not skip the safety try/rescue in CLI main. A crash exits
  non-zero; the dev shepherd propagates exit 2 instead of waiting
  for a source change.
- Does not change the LV's view of the world — the dev BEAM and
  the prod release-installed BEAM render identically. The only
  difference is the watch-and-restart loop on the outside.

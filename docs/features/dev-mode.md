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
   `mix run --no-start --no-compile`. Exit code 75 means "restart
   on the same port" (the deterministic port derived from
   `shasum -a 256 cwd:args`, range 40000–59999). Any other
   non-zero exit in `MIX_ENV=dev` is also treated as "stay alive"
   — the shepherd blocks on `find -newer` waiting for the next
   source change and retries. Crash loops are bounded by the file-
   change wait; CPU stays idle.

Phoenix LiveView's client auto-reconnects when the BEAM dies on
exit 75. The browser tab stays put. State survives because:

- Comments + approvals are persisted to
  `<gitdir>/meerkat-precommit/in-progress/<review_id>.json` and
  reloaded by `ReviewServer.init/1`.
- The open inline comment form is persisted to the same file via
  `ReviewState.open_form`. After reconnect, `ReviewLive.mount/3`
  re-assigns it and `DiffViewer` re-injects the form at the same
  anchor.
- Body content typed into the form is held in `localStorage`
  under a `draftKey` keyed on the anchor; re-opening the same
  anchor reads it back.

## Deterministic port

The port is `int(shasum256(cwd:args)[:8]) % 20000 + 40000`. The
same (working directory, args) tuple always maps to the same
port across:

- A DevWatcher-triggered restart in this shepherd.
- A fresh `git commit` invocation that re-fires meerkat-beam from
  the same repo.

So the user's browser tab keeps working without manual
re-navigation. Range 40000–59999 keeps us above the privileged
range but below the OS-ephemeral default start on macOS
(49152–65535) — collisions with random OS allocations are rare,
not impossible. If Bandit can't bind, the CLI logs a warning and
the shepherd retries.

`MEERKAT_PORT` env var overrides the deterministic computation
for tests / debugging.

## What dev mode does NOT do

- Does not install on `main`. Merge → re-runs `scripts/install.sh`
  which overwrites the dev launcher with the prod release.
- Does not skip the safety try/rescue in CLI main. A crash still
  exits non-zero; in dev the shepherd just doesn't propagate.
- Does not change the LV's view of the world — the dev BEAM and
  the prod release-installed BEAM render identically. The only
  difference is the watch-and-restart loop on the outside.

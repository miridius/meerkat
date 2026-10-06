# CLI

`meerkat [TARGET-SPEC] [FLAGS]`

## Targets

Exactly one target — precedence top-down if more than one is
supplied (no error, the highest-precedence one wins):

- `--pr <NUMBER-OR-URL>` — GitHub PR review. `gh` resolves PR
  metadata; meerkat fetches `refs/pull/<N>/head` + the PR's base
  branch via `git fetch +refs/pull/<N>/head:refs/meerkat-pr/<N>/head`,
  then renders the three-dot diff `base...head`.
- `<REF>` — `meerkat HEAD`, `meerkat abc1234`, etc. Renders
  `<ref>~1...<ref>` — the diff that ref introduced.
- `A..B` (two-dot) — symmetric diff, base..head.
- `A...B` (three-dot) — diff vs merge-base.
- `--commit-msg <PATH>` — staged-diff review with a commit-msg
  gutter on top. The pre-commit hook context. `<PATH>` is the
  commit-message file git is about to use (e.g.
  `.git/COMMIT_EDITMSG`).
- *(no target)* — staged-diff review without a commit-msg gutter.

Staged-diff reviews omit paths with unresolved merge conflicts; other
staged files are still reviewed. For which index they read, see
[`GIT_INDEX_FILE`](#env-vars).

## Flags

- `--answers` — no review. Read the agent's answers to a prior
  review's question comments as JSON on stdin, validate them, store
  them as the pending-answers file (see
  [pending-answers.md](pending-answers.md)) and exit: `0` stored, `1`
  rejected with the reason on stderr. Rejected alongside a ref/range,
  `--pr` or `--commit-msg`. The launcher runs this invocation once in
  the foreground, outside its restart loop, so stdin reaches the BEAM.
- `--no-open` — don't shell out to `open`/`xdg-open`/`cmd start` to
  open the browser. Use when meerkat is being driven by an
  automated test or remote dev session.
- `--port <N>` (or `--port=<N>`) — set the HTTP server's port. The
  CLI defaults to `0`; with `0`, it binds a valid
  `MEERKAT_PREFERRED_PORT` if it is free, and binds an OS-assigned
  port only if there is no valid preferred port or it is in use.
  Launchers pass explicit options through and ignore `MEERKAT_PORT`
  for them; on respawn they may supply the last-bound port as a
  preference. A nonzero `N` binds exactly `N`; if occupied, meerkat
  reports the conflict and exits `64`.

## Env vars

- `MEERKAT_PWD` — set by the launcher to the caller's cwd, so git
  operations target the user's repo regardless of where the BEAM
  release lives. Inside the BEAM, `Meerkat.CLI.repo_path/0` uses
  this then falls back to `File.cwd!/0`.
- `MEERKAT_PORT` — for tests/debugging, the launcher copies this to
  `MEERKAT_PREFERRED_PORT` when set and no explicit `--port` is
  present, instead of using the stable review port. Explicit `--port`
  options ignore it; invalid values are copied and reported by the
  CLI as an invalid preferred port.
- `MEERKAT_PREFERRED_PORT` — the launcher discards any inherited
  value. With no explicit `--port`, it sets this initially from
  `MEERKAT_PORT` or the stable review port; after each BEAM exit it
  sets it to the port in the run dir's `port` file for the next BEAM,
  then removes the file. The CLI tries it when `--port` is `0`;
  values outside 1–65535 are ignored with a warning, and an occupied
  preferred port falls back to OS-assigned.
- `MEERKAT_INSTALL_PREFIX` — defaults to `~/.local/share/meerkat-beam`.
  Where the release directory + `.mode` marker live.
- `MEERKAT_BIN_DIR` — defaults to `~/.local/bin`. Where the
  launcher script is written.
- `MEERKAT_BIN` — used by the Playwright e2e suite to point at the
  binary under test (`bin/meerkat-beam` for in-tree dev, or
  `~/.local/bin/meerkat` for the installed launcher).
- `MEERKAT_REVIEW_TIMEOUT` — review deadline in whole seconds (default
  90 minutes). `0` removes the deadline and countdown; unparseable
  values are ignored.
- `MEERKAT_AUTO_APPROVE_ON_TIMEOUT` — `1`, `true`, or `yes` turns on
  auto-approval at timeout, ignoring case and surrounding whitespace.
  Unset, empty, `0`, `false`, or `no` leaves it off and the review open
  after timeout. Any other value prints a one-line stderr warning
  naming the value and leaves auto-approval off.
- `GIT_INDEX_FILE` — Staged-diff reviews read the index git gave the
  hook, so `git commit -a` and `git commit <path>` are reviewed as they
  will be committed. A relative name is taken from the top of the work
  tree, as git takes it. The review keeps its own copy of a temporary
  index, so it keeps showing those changes and accepting decisions
  after git removes the original, including after the review server
  restarts. If it cannot keep that copy, because git has already
  removed the index (for example, `git commit` was killed before the
  review started) or the copy failed, meerkat exits `2` with a message
  and defaults to REJECT rather than showing every file as deleted.
  `GIT_DIR`, `GIT_WORK_TREE`, and other variables that relocate the
  repo remain ignored.

  The launcher sends the invocation's value with every attach to a
  running review. An attach is matched by the staged content in its
  named index and the commit message, not the index filename; if no
  index is named, meerkat reads the repo's own index. A retried
  `git commit <path>` therefore attaches to the same review and gets
  its held decision even though git gives its temporary index a new,
  process-id-based name each run. If the named index has different
  staged content (for example, `git commit -a` after a plain
  `git commit` when tracked files have unstaged changes that `-a` would
  include) or the commit message differs, the old server exits and the
  invocation starts a new one. If the named index no longer exists, the
  invocation prints `meerkat: error resolving review target: the index
  <path> no longer exists` and exits `64`; the running review keeps
  going, along with any decision it holds. Reviews of other targets
  ignore the value.
- `BASE_BRANCH` — override `origin/main` in `scripts/mutate.sh
  changed` mode.
- `FORCE=1` — let `scripts/install.sh` override the dev-mode
  marker and reinstall the prod release.

## Exit codes

- `0` — approved (with or without feedback). The git hook proceeds
  with the commit. Under `--answers`: the answers were stored.
- `1` — rejected, or cancelled. The git hook aborts. Under
  `--answers`: the input was rejected and nothing was written.
- `2` — an unhandled crash downstream of `Meerkat.CLI.main/1`. The
  outer `try/rescue` defaults to REJECT + exit 2 so a crash never
  silently lands a commit; see [decision-flow.md](decision-flow.md).
  The dev launcher (`bin/meerkat-beam`) propagates exit 2; the prod
  launcher (`bin/meerkat-shepherd`) retries a crash once, then exits
  with the code. A caller that cannot create its run dir while not
  attached to a serving BEAM exits 2 with a REJECT message (`could
  not create <run dir>`); an already attached caller still receives
  the decision and exits with it. A staged review that cannot keep a
  copy of the commit's temporary index exits 2 with a REJECT message;
  see [`GIT_INDEX_FILE`](#env-vars). While waiting to retry after a
  failed build, the dev launcher exits 2 with a REJECT message if its
  checkout or `$MEERKAT_PWD` is deleted. Under `--answers`: the dev
  launcher could not build meerkat, so it stored nothing.
- `64` — the arguments were rejected (unknown flag, conflicting
  positional, etc.), an explicit nonzero `--port` was already in use,
  or the review target didn't resolve (a bad ref, a failed `--pr`
  fetch). A later invocation of a running staged review also exits 64
  when its `GIT_INDEX_FILE` names an index that no longer exists; see
  [`GIT_INDEX_FILE`](#env-vars). The launchers pass it straight through. Under `--answers`:
  a terminal on stdin, or a directory that is no git repository.
- `74` — `--answers` could not read stdin, or could not write the
  answers file. Nothing was stored, and the input itself was fine.
- `75` — DevWatcher restart sentinel. Internal to
  `bin/meerkat-beam`'s shepherd loop — never reaches the git hook.

## Output

- **stdout**: nothing in normal operation.
- **stderr**: an agent-facing pause banner when the review UI comes up
  (`⏸ Paused for human review at <url> — may take minutes or hours.`
  followed by wait-don't-poll instructions and the exit-code meanings;
  the wording is target-aware — only a staged review with a
  commit-msg path, i.e. the hook flow, says `git commit` /
  "approved & landed"), `debug logs at: <path>`, auto-approve
  breadcrumbs, warnings, a plain user-attributed verdict line on every
  terminal decision, and — on approve-with-feedback / reject — the
  rendered comment feedback (see [decision-flow.md](decision-flow.md)).
  The CLI sets stderr to UTF-8 at startup, so all output it writes to
  stderr is UTF-8 regardless of the locale.
- **logfile**: Phoenix/Bandit/LiveView Logger output is redirected to
  `<gitdir>/meerkat-precommit/meerkat.log` before the endpoint boots,
  so the server logs stay out of the agent-facing stream.

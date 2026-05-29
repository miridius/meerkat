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

## Flags

- `--no-open` — don't shell out to `open`/`xdg-open`/`cmd start` to
  open the browser. Use when meerkat is being driven by an
  automated test or remote dev session.
- `--port <N>` — bind the HTTP server to a specific port. `0` (the
  default) means "OS-assigned", which is what real users want;
  hardcoded ports collide between concurrent meerkat instances.

## Env vars

- `MEERKAT_PWD` — set by the launcher to the caller's cwd, so git
  operations target the user's repo regardless of where the BEAM
  release lives. Inside the BEAM, `Meerkat.CLI.repo_path/0` uses
  this then falls back to `File.cwd!/0`.
- `MEERKAT_INSTALL_PREFIX` — defaults to `~/.local/share/meerkat-beam`.
  Where the release directory + `.mode` marker live.
- `MEERKAT_BIN_DIR` — defaults to `~/.local/bin`. Where the
  launcher script is written.
- `MEERKAT_BIN` — used by the Playwright e2e suite to point at the
  binary under test (`bin/meerkat-beam` for in-tree dev, or
  `~/.local/bin/meerkat` for the installed launcher).
- `BASE_BRANCH` — override `origin/main` in `scripts/mutate.sh
  changed` mode.
- `FORCE=1` — let `scripts/install.sh` override the dev-mode
  marker and reinstall the prod release.

## Exit codes

- `0` — approved (with or without feedback). The git hook proceeds
  with the commit.
- `1` — rejected, or cancelled. The git hook aborts.
- `2` — argument parsing error (unknown flag, conflicting
  positional, etc.) OR an unhandled crash downstream of
  `Meerkat.CLI.main/1`. The outer `try/rescue` defaults to REJECT
  + exit 2 so a crash never silently lands a commit; see
  [decision-flow.md](decision-flow.md).
- `75` — DevWatcher restart sentinel. Internal to
  `bin/meerkat-beam`'s shepherd loop — never reaches the git hook.

## Output

- **stdout**: nothing in normal operation.
- **stderr**: status messages (`human review UI at ...`, `debug logs
  at: <path>`, auto-approve breadcrumbs, warnings), a plain
  user-attributed verdict line on every terminal decision, and — on
  approve-with-feedback / reject — the rendered comment feedback (see
  [decision-flow.md](decision-flow.md)).
- **logfile**: Phoenix/Bandit/LiveView Logger output is redirected to
  `<gitdir>/meerkat-precommit/meerkat.log` before the endpoint boots,
  so the server logs stay out of the agent-facing stream.

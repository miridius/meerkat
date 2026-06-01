# Meerkat

A small local diff reviewer. **Phoenix LiveView + LiveSvelte on the
BEAM**. See `README.md` for what it does and how to install it.

## Public repository

This repo is **public**. Anything committed or pushed — code, commit
messages, branch names, PR titles and descriptions — is world-visible
and effectively permanent (squashing or deleting a branch does not
remove commits a merged PR still references). Before committing:

- No secrets, no internal or company references, no local absolute
  paths (`/Users/…`, `~/.claude/…`), no work email addresses.

## Rules

- **Elixir + Bun.** `mix …` for backend, `bun …` for the Playwright
  e2e suite. Never npm/npx/node directly — bun owns JS tooling.
- **No mock/demo data.** The review UI runs against real diffs. If you
  need test data, write a real commit / range / PR.

## Workflow

The end-to-end loop for a meerkat bug report or feature request:

1. **Understand.** If the request is ambiguous, ask clarifying
   questions before touching code. If the work is non-trivial
   (multi-file, design choices, more than one viable approach),
   invoke `/brainstorm` and let plan mode shape Context →
   Requirements → Design → Plan with the user's input — don't
   write the plan in chat.
2. **Build, test, verify.** Implement in small slices. Each slice
   ends with `mix test` green AND a manual verification:
   `iex -S mix phx.server` for dev iteration (Vite hot-reloads
   Svelte changes), or `MEERKAT_BIN=$PWD/bin/meerkat-beam bun
   run test:e2e` for the Playwright suite end-to-end.
3. **Keep going until it's PR-ready, and meet every requirement in
   the plan.** Don't stop part way through. Don't ask the user
   "should I continue?" or "should I do X later?" — just do it.
   "Out of scope" is not an escape hatch for a requirement the user
   already approved; if the work spans repos or layers, ship all of
   them in this PR (vendor cross-repo bits if needed). The session
   ends when every requirement is met and the work is on a
   reviewable branch, not when a response boundary feels
   convenient.
4. **Ship.** Branch off `main`, commit, push, and open a **draft** PR.
   `main` is branch-protected on GitHub — no direct pushes, no
   force-pushes; changes land via PR. This is a public repo: get the
   user's OK before pushing or opening a PR.

## Quality gates

Pre-commit hook (`bash scripts/check.sh`):
- `mix format --check-formatted`
- `mix compile --warnings-as-errors`

Pre-push hook: `mix test` (ExUnit + LiveViewTest).

You can run them yourself any time:

```bash
mix compile --warnings-as-errors
mix format
mix test
bun run test:e2e                     # Playwright — exercises the bin/meerkat-beam launcher
```

When you change behaviour, change or add a test — ExUnit in
`test/**/*_test.exs`, Playwright e2e in `tests/e2e/*.spec.ts`. The
Playwright suite IS the behavioural contract.

## Mutation testing

`scripts/mutate.sh` runs `mix muex` against `lib/meerkat/*.ex` to
surface untested behaviour: muex rewrites operators / literals one
at a time and re-runs the test suite — a rewrite the suite still
passes against is a test gap.

```bash
scripts/mutate.sh                # all lib/meerkat/*.ex (slow)
scripts/mutate.sh changed        # only files changed vs origin/main
scripts/mutate.sh lib/meerkat/git.ex   # one or more named files
scripts/mutate.sh changed -- --fail-at 95 --concurrency 4
```

Run `scripts/mutate.sh changed` locally before opening a PR. It's
not wired into a hook — mutation tests can take minutes per
module and the signal is best surfaced by a human reading the
survivor list.

## Local dev mode

When iterating on UI / Svelte / CSS: `scripts/dev-install.sh`
overwrites `~/.local/bin/meerkat` with a thin launcher that runs
`bin/meerkat-beam` from THIS checkout under `MIX_ENV=dev`. Every
`meerkat` invocation (from any repo) boots a BEAM whose code is
read directly from this tree, so:

- Edits to `assets/svelte/*.svelte` / `assets/css/*.css` need a
  meerkat restart so `bin/meerkat-beam`'s pre-flight rebuilds
  `priv/static/` via `vite build`. There is no Vite dev server / HMR
  in this setup — see `config/dev.exs` for the rationale.
- Edits to `lib/meerkat/*.ex` / `lib/meerkat_web/**/*.ex` are
  picked up by `Meerkat.DevWatcher` — it halts the BEAM with exit
  code 75 on any file change under `lib/`, the shepherd loop in
  `bin/meerkat-beam` respawns on the same port, and LiveView's
  client auto-reconnects. Phoenix's request-time code reloader is
  off in dev (it fought `Meerkat.CLI`'s `Application.put_env` +
  manual-supervisor startup pattern); the DevWatcher restart is
  the dev-iteration story.

```bash
scripts/dev-install.sh        # ~/.local/bin/meerkat → this branch
meerkat                       # any repo, restart on lib/ or assets/ edits
scripts/install.sh            # revert to prod release
```

`dev-install.sh` refuses to run while HEAD is `main` — dev mode is
for unmerged work. Bringing local `main` up to date — via `git pull`,
or by `git switch`/`git checkout main` after a GitHub squash-merge —
fires the lefthook `post-merge` / `post-checkout` hooks, which run
`scripts/install.sh` (via `scripts/auto-install.sh`) and replace the
dev launcher with the prod release. install.sh is idempotent (it
skips the rebuild when the release is already built from the current
commit), so the hooks are cheap to fire on every `main` checkout.
There is no state marker file; the launcher script content IS the mode.

`bin/meerkat-beam` (the underlying launcher) is also runnable
directly for ad-hoc dev — `MEERKAT_BIN=./bin/meerkat-beam bun run
test:e2e` is the e2e suite's entry point.

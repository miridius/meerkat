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
- No Claude Code session URLs.

## Rules

- **Elixir + pnpm + Bun.** `mix …` for backend. JS dependencies are
  installed ONLY with `pnpm install` (the workspace root covers
  `assets/`; `pnpm-workspace.yaml` enforces a 24h minimum release
  age as a supply-chain guard). `bun run` / `bunx` for
  running scripts and the Playwright e2e suite. Never npm/npx/node
  directly, and never `bun install` — there must be no `bun.lock`.
- **Keep dependencies current — enforced.** `scripts/outdated.sh`
  FAILS while any JS or Hex package is behind its latest
  release. The pre-commit hook bumps outdated packages. Don't bump
  them by hand. Fix the fallout rather than pin old versions. A
  deliberate pin is a narrow, per-release record of a specific
  upstream breakage: each entry in `scripts/dep-exemptions.json` must
  include a `version` and non-empty `reason`, and exempts only that
  release while it is latest. When a newer release appears, the
  pre-commit hook bumps to it as usual; a missing or malformed
  `scripts/dep-exemptions.json` file, or a stale entry, fails
  `scripts/outdated.sh`. JS releases younger than the 24h min-age
  floor get an automatic grace pass (Hex has no floor, so no grace).
  The gate fails closed on its own breakage.
- **No mock/demo data.** The review UI runs against real diffs. If you
  need test data, write a real commit / range / PR.

## Workflow

The end-to-end loop for a meerkat bug report or feature request:

1. **Understand.** If the request is ambiguous, ask clarifying
   questions before touching code.
2. **Build, test, verify.** Implement in small slices. Each slice
   ends with `mix test` green AND a manual verification: review a
   real diff through `bin/meerkat-beam` from this checkout and use
   the changed behaviour. Once `bun run test` passes, and before
   the PR is opened, the `meerkat-qa` agent exercises the changed
   behaviour the way a user meets it. Turn each QA-found bug into a
   test that fails before the fix, at the lowest layer that reaches
   it; use e2e only when lower-layer tests cannot reach the seam,
   1-3 tests per seam.
3. **Keep going until it's PR-ready, and meet every requirement the
   user asked for or approved.** Don't stop part way through. Don't
   ask the user "should I continue?" or "should I do X later?" — just
   do it. "Out of scope" is not an escape hatch for a requirement the
   user asked for or approved; if the work spans repos or layers, ship
   all of them in this PR (vendor cross-repo bits if needed). The session
   ends when every requirement is met and the work is on a
   reviewable branch, not when a response boundary feels
   convenient.
4. **Ship.** Branch off `main`, commit, push, and open a **draft** PR.
   Do not ask before pushing or opening the PR. `main` is
   branch-protected on GitHub — no direct pushes, no force-pushes;
   changes land via PR.

## Quality gates

**Pre-commit:** Lefthook runs `scripts/no-main-commits.sh`, then `scripts/bump-deps.sh`, then `scripts/check.sh`. They are piped, so if one script refuses the commit, the later ones do not run.

`bump-deps.sh` upgrades each non-exempt Hex and JS package that `scripts/outdated.sh` would report. It stages the changed `mix.exs`, `mix.lock`, `package.json` files and `pnpm-lock.yaml` into the commit. A Hex requirement in `mix.exs` moves when the latest release is outside it. JS ranges move with `pnpm update --latest`, which keeps the 24h release-age floor.

`check.sh` skips the checks when nothing is staged or all staged changes are Markdown-only. Otherwise, it runs these steps in order:

1. `mix deps.get`
2. `pnpm install --frozen-lockfile --ignore-scripts --prefer-offline`
3. `mix compile --warnings-as-errors`
4. `mix format --check-formatted`
5. `mix credo --strict`
6. `bunx biome lint --error-on-warnings`
7. `mix test`
8. `bun test` in `assets/`
9. `bun test tests/e2e/lib` from the repo root
10. `bun run build` in `assets/`
11. `bunx playwright install --only-shell chromium`
12. `bun run test:e2e`

Biome is configured by `biome.json` and lints JS, TS, CSS, and Svelte files, including Svelte templates and styles. Biome warnings and errors fail the check; infos are printed only.

**Pre-push:** `.lefthook/pre-push/pre-push.sh` runs `scripts/no-private-refs.sh` and `scripts/outdated.sh` for pushes that include updates. A push that only deletes refs skips these checks. The script runs both checks so each can report its findings; if either fails, the push is blocked.

**CI:** Every PR runs, in order, `mix deps.get`, `pnpm install --frozen-lockfile --ignore-scripts`, `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `bunx biome lint --error-on-warnings`, `mix test`, `bun test` in `assets/`, `bun test tests/e2e/lib` from the repo root, `bunx playwright install --only-shell chromium`, and `bun run test:e2e`. The Playwright suite's global setup (`tests/e2e/lib/setup.ts`) builds the assets by running `bin/meerkat-beam` with `MEERKAT_BUILD_ONLY=1`. CI runs these checks even when the local hooks skip them.

`bun run test` runs `mix test`, then `bun test` in `assets/`, then `bun test tests/e2e/lib` from the repo root, then `bun run test:e2e`.

When behaviour changes, choose the lowest layer that exercises it:
- Use ExUnit (`test/**/*_test.exs`, including LiveViewTest) or asset
  `bun test` for behaviour they can reach.
- Use Playwright (`tests/e2e/*.spec.ts`) only for seams those tests
  cannot reach, 1-3 tests per seam: browser Svelte/JS to LiveView,
  CLI to BEAM exit/stdout, and process lifecycle.
- Keep owned/local behaviour real; mock only boundaries we don't own.

## Mutation testing

`scripts/mutate.sh` runs `mix muex` against `lib/meerkat/*.ex` to
surface untested behaviour: muex rewrites operators / literals one
at a time and re-runs the test suite — a rewrite the suite still
passes against is a test gap.

```bash
scripts/mutate.sh                # lib/meerkat/*.ex except application.ex (slow)
scripts/mutate.sh changed        # only files changed vs origin/main
scripts/mutate.sh lib/meerkat/git.ex   # one or more named files
scripts/mutate.sh changed -- --fail-at 95 --concurrency 4
```

Run `scripts/mutate.sh changed` locally before opening a PR; do not add it to automatic hooks, since runs take minutes per module.

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
  `bin/meerkat-beam` respawns, preferring the port its previous BEAM
  bound, and LiveView's client auto-reconnects to the new BEAM only
  when it binds the port the previous BEAM bound.
  Phoenix's request-time code reloader is off in dev (it fought
  `Meerkat.CLI`'s `Application.put_env` + manual-supervisor startup
  pattern).

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
dev launcher with the prod release. There is no state marker file;
the launcher script content IS the mode.

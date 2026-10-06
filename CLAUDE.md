# Meerkat

A small local diff reviewer. **Phoenix LiveView + LiveSvelte on the
BEAM**. See `README.md` for what it does and how to install it.

## Public repository

This repo is **public**. Anything committed or pushed — code, commit
messages, branch names, PR titles and descriptions — is world-visible
and effectively permanent (squashing or deleting a branch does not
remove commits a merged PR still references). Before committing:

- No secrets, content specific to the owner's employer, local absolute
  paths (`/Users/…`, `~/.claude/…`), or work email addresses. The owner's
  Claude Code plugins, skills and agents may be named and described;
  these bans still apply.
- No Claude Code session URLs.

## Rules

- **Elixir + pnpm + Bun.** `mix …` for backend. JS dependencies are
  installed ONLY with `pnpm install` (the workspace root covers
  `assets/`; `pnpm-workspace.yaml` enforces a 24h minimum release
  age as a supply-chain guard). `bun run` / `bunx` for
  running scripts and the Playwright e2e suite. Never npm/npx/node
  directly, and never `bun install` — there must be no `bun.lock`.
- **Keep dependencies current — enforced.** `scripts/outdated.sh` fails
  when a direct JS or Hex dependency trails its latest release unless
  that release is exempt. JS releases under 24h are not required, and a
  Hex release in cooldown is not required only when all requirements in
  `mix.exs` and other dependencies admit it; otherwise, it is treated as
  outdated and blocks the gate unless exempted. In either ecosystem, an
  exemption is stale if the package is no longer behind or its named
  version does not match the latest reported version (the JS registry's
  latest or `Latest` in `mix hex.outdated` for Hex), even if that latest
  release is not yet required.
  The gate also fails on any git dependency unless an exemption names
  its latest stable Hex release and its pinned commit contains that
  release; one without a stable Hex release cannot be exempted, and a
  new stable release makes its entry stale immediately. The pre-commit
  hook bumps registry packages; do not bump them by hand. It never
  moves git dependencies, so maintain
  their exemptions by hand. Fix fallout rather than pinning old
  releases. Each `scripts/dep-exemptions.json` entry needs a `version`
  and non-empty `reason`; missing or malformed files and stale entries
  fail the gate. The gate fails closed.
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

   Before opening the draft PR, do a quick self-review of the diff
   and the PR description you are about to post, so unchecked work
   does not reach the user when the PR opens. Does it do what was
   asked? Is it sensible? Does it avoid unnecessary changes or
   complexity? Fix every finding from any review you run before
   opening the PR, regardless of which review found it. Keep this
   self-review cheap: it must not add review agents,
   mutation-testing runs, or extra test suites of its own. The
   thorough review still happens at merge through
   `/review-and-merge`; this self-review does not replace it.

   When a PR changes what meerkat's review page shows, screenshots are
   called for. Use judgement to choose whichever screenshots, and how
   many, will help review that PR; for changed UI, a before/after pair
   can help.

## Quality gates

**Pre-commit:** Lefthook runs `scripts/no-main-commits.sh`, `scripts/bump-deps.sh`, `scripts/check.sh`, then `scripts/mutate.sh staged`. They are piped, so if one script refuses the commit, later scripts do not run.

`bump-deps.sh` bumps non-exempt outdated Hex and JS packages, moving a `~>` requirement in `mix.exs` to latest when needed. It refuses the commit when it cannot rewrite a requirement or an update fails, never moves git dependencies, and stages changed `mix.exs`, `mix.lock`, `package.json`, `pnpm-lock.yaml`, and `assets/package.json` into the commit.

`check.sh` skips the checks when nothing is staged or all staged changes are Markdown-only. Otherwise, it runs these steps in order:

1. `mix deps.get`
2. `pnpm install --frozen-lockfile --ignore-scripts --prefer-offline`
3. `mix compile --warnings-as-errors`
4. `mix format --check-formatted`
5. `mix credo --strict`
6. `bunx biome lint --error-on-warnings`
7. `bash scripts/mix-test.sh`
8. `bun test` in `assets/`
9. `bun test tests/e2e/lib` from the repo root
10. `bun run build` in `assets/`
11. `bunx playwright install --only-shell chromium`
12. `bun run test:e2e`

Biome is configured by `biome.json` and lints JS, TS, CSS, and Svelte files, including Svelte templates and styles. Biome warnings and errors fail the check; infos are printed only.

**Pre-push:** `.lefthook/pre-push/pre-push.sh` runs `scripts/no-private-refs.sh` and `scripts/outdated.sh` for pushes that include updates. A push that only deletes refs skips these checks. The script runs both checks so each can report its findings; if either fails, the push is blocked. `no-private-refs.sh` reads private patterns, one extended regex per line, from the untracked `info/private-refs` in the git common dir and refuses the push if that file is missing or any pattern fails its self-test. It scans commits not already held by the target remote, plus every pushed tip’s full tree, pushed annotated tags, and pushed ref names, rejecting private-pattern matches, Claude Code session URLs, local absolute paths, and all email addresses except placeholder and no-reply addresses. It refuses the push if the remote cannot be queried.

**CI:** Every PR runs, in order, `mix deps.get`, `pnpm install --frozen-lockfile --ignore-scripts`, `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `bunx biome lint --error-on-warnings`, `mix test`, `bun test` in `assets/`, `bun test tests/e2e/lib` from the repo root, `bunx playwright install --only-shell chromium`, and `bun run test:e2e`. The Playwright suite's global setup (`tests/e2e/lib/setup.ts`) builds the assets by running `bin/meerkat-beam` with `MEERKAT_BUILD_ONLY=1`. CI runs these checks even when the local hooks skip them.

`bun run test` runs `scripts/mix-test.sh`, then `bun test` in `assets/`, then `bun test tests/e2e/lib` from the repo root, then `bun run test:e2e`.

When behaviour changes, choose the lowest layer that exercises it:
- Use ExUnit (`test/**/*_test.exs`, including LiveViewTest) or asset
  `bun test` for behaviour they can reach.
- Use Playwright (`tests/e2e/*.spec.ts`) only for seams those tests
  cannot reach, 1-3 tests per seam: browser Svelte/JS to LiveView,
  CLI to BEAM exit/stdout, and process lifecycle.
- Keep owned/local behaviour real; mock only boundaries we don't own.

## Mutation testing

`scripts/mutate.sh` runs muex to test whether ExUnit tests detect mutations. With no argument, it mutates every line of every `lib/meerkat/*.ex` file except `lib/meerkat/application.ex` and is slow. `changed` mutates only changed lines in `lib/**/*.ex` relative to the merge base with `origin/main` (`BASE_BRANCH` overrides the base), including uncommitted edits. `staged` mutates only `lib/**/*.ex` lines staged for the next commit; the pre-commit hook uses this mode. It exits 0 immediately when no matching lines are staged. Otherwise it adds minutes to the commit. A staged file with unstaged edits blocks the commit. A surviving mutant or one reported as `no_coverage` (no ExUnit test executes its line) blocks the commit; each is reported with its file, line, status, and code change. Timed-out mutants count as killed. Staged lines that produce no mutants pass. One or more file paths mutate every line of those files. Put extra muex flags after `--`.

```bash
scripts/mutate.sh
scripts/mutate.sh changed
scripts/mutate.sh staged
scripts/mutate.sh lib/meerkat/git.ex
scripts/mutate.sh changed -- --concurrency 4
```

Every blocking mutant must be killed by a test in the same commit, except for the kinds listed under “Acceptable non-fixes” in `.claude/skills/review-and-merge/SKILL.md`: equivalent mutants, pure-observability mutations, and unreachable I/O seams. For one of these exceptions, put a `# muex:ignore <reason>` comment on its own line directly above the mutated line, in a position that `mix format` leaves in place, with a reason explaining why it qualifies; muex reports every mutant on the line below an annotated comment as ignored, so none blocks the commit, whatever its status would otherwise have been. Do not use this comment for any other survivor. Never bypass the hook with `--no-verify`.

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
dev launcher with the prod release.

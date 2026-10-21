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

- **Elixir + pnpm + Bun.** Set up a checkout with `mise install` (the
  Erlang, Elixir and Bun `.tool-versions` pins), `bun
  scripts/setup-toolchain.ts` (the Hex and rebar3
  `.github/toolchain.env` pins), `mix deps.get`, then
  `pnpm install --frozen-lockfile`. The tests also need `clj-kondo` on
  PATH. `mix …` for backend. As a supply-chain guard, Hex and pnpm
  resolve no release under 24h old: `mix.exs` sets Hex's `cooldown`,
  and `pnpm-workspace.yaml` sets `minimumReleaseAge`. JS dependencies
  are installed ONLY with `pnpm install` (the workspace root covers
  `assets/`). `bun run` / `bunx` for
  running scripts and the Playwright e2e suite. Never npm/npx/node
  directly, and never `bun install` — there must be no `bun.lock`.
- **Keep dependencies current — enforced.** `scripts/outdated.sh` fails
  when a direct JS or Hex dependency trails its latest release unless
  that release is exempt. A JS release isn't required while it, or a
  package version it requires, is under the 24h minimum release age. A
  Hex release isn't required while it is under 24h old. In either
  ecosystem, an exemption is stale if the package is no longer behind or its named
  version does not match the latest reported version (the JS registry's
  latest or `Latest` in `mix hex.outdated` for Hex), even if that latest
  release is not yet required.
  A git dependency counts as current when its pinned GitHub commit
  contains the tag of its newest stable Hex release at least 24h old. The gate fails for
  all other git dependencies. None is exempt. The pre-commit
  hook bumps registry packages; do not bump them by hand. It never
  moves git dependencies, so maintain
  their pins by hand. Fix fallout rather than pinning old
  releases. Each `scripts/dep-exemptions.json` entry needs a `version`
  and non-empty `reason`; missing or malformed files and stale entries
  fail the gate. Before reading their reports, the gate and the bump
  install the locked dependencies, and fail when that would change
  `mix.lock` or `pnpm-lock.yaml`. The gate fails closed.
  The toolchain is held to the same floor: `scripts/toolchain.ts`
  fails the gate when a pin in `.tool-versions` or
  `.github/toolchain.env`, `package.json`'s `packageManager`, or a
  workflow's action SHA is not the newest release at least 24h old,
  and the pre-commit hook bumps them. The one exception is a security
  fix: when a published advisory affects a dependency's current
  version, or a tool's newest release 24h old, the release that fixes
  it is taken however young. While none does, a tool's pin moves to
  the newest release no advisory covers that is 24h old and not older
  than the pin, or else to a newer one however young, and otherwise
  never to an older release.
  pnpm checks its lockfile against the floor too, so each such JS or
  pnpm release under 24h old keeps an exact `name@version` entry in
  `pnpm-workspace.yaml`'s `minimumReleaseAgeExclude`; the pre-commit
  hook drops each entry once it is 24h old, and the gate fails on one
  that is.
- **Script languages.** Write repo scripts (`scripts/`, `bin/`, hooks)
  with any branching, looping or parsing in TypeScript run by Bun.
  Bash only for a few lines of glue that set up and exec. Elixir
  (`.exs`) only for jobs on Elixir/Mix source or needing app code. No
  Perl or other runtime; adding a language needs the manager's approval.
  Existing bash scripts are being moved to TypeScript, one family per PR;
  until a bash script moves, code that must run in its own process, such
  as `scripts/gate-lock.sh`, stays bash with it.
- **No mock/demo data.** The review UI runs against real diffs. If you
  need test data, write a real commit / range / PR.
- **Headless browsers only.** Agents never open a visible browser
  window on the user's screen: run Playwright headless, any Chrome they
  launch with `--headless=new`, and pass `--no-open` to every meerkat
  they run themselves. A git hook's meerkat, which opens for the
  user's review, is exempt.

## Workflow

The `dev-process` and `pull-requests` plugins from the
`miridius-public` marketplace, enabled in `.claude/settings.json`,
hold the development-process and PR rules. The loop below adds
meerkat's own steps for a bug report or feature request:

1. **Spec.** A feature's spec, which a big feature's spec-only PR
   changes, is its `docs/features/*.md` file.
2. **Build, test, verify.** Implement in small slices. Each slice
   ends with `mix test` green AND a manual verification: review a
   real diff through `bin/meerkat-beam` from this checkout and use
   the changed behaviour. Once `bun run test` passes, and before
   the PR is opened, the `meerkat-qa` agent exercises the changed
   behaviour the way a user meets it. Turn each QA-found bug into a
   test that fails before the fix, at the lowest layer that reaches
   it; use e2e only when lower-layer tests cannot reach the seam,
   1-3 tests per seam. Tests pass `--no-open`.
   A run that needs a browser (Playwright, `meerkat-qa`) opens the
   printed URL itself.
3. **Ship.** Commit and push without asking first.
   `main` is branch-protected on GitHub — no direct pushes, no
   force-pushes; changes land via PR.

## Quality gates

**Pre-commit:** Lefthook runs `scripts/no-main-commits.sh`, `scripts/bump-deps.sh`, `scripts/check.sh`, then `scripts/mutate.sh staged`. They are piped, so if one script refuses the commit, later scripts do not run. Lefthook prints their output as it comes.

**Gate slots:** At most two gates in all worktrees of the repo run their checks at once. `check.sh`, in either mode, and `mutate.sh staged` or `changed` each take one of two slots from `scripts/gate-lock.sh` before their checks and free it when they end. A gate that finds both slots taken, or other gates waiting ahead of it, prints that it is waiting. Gates take slots first come, first served: each takes a ticket named for the time it started waiting, a file in `meerkat-gate-lock/waiting` that it holds a `lockf` lock on, and only the gate with the earliest live ticket tries the slots, so no gate is overtaken by one that started waiting later. Under bash before 5 a ticket is named for the start of its second, so such a gate can overtake one that started earlier in that second. A ticket whose gate died is unlocked; the next gate to find it deletes it. Gates on the script from before tickets wait for a lock on `meerkat-gate-lock/queue` instead. The gate with the earliest ticket takes that lock when it is free and holds it until it gets a slot, stops being the earliest, or gives up; while one of those gates holds it, the two race for the slots. A waiting gate tries the locks once a second rather than blocking, since `lockf` blocked on an fd spins a core, and gives up, failing the gate, after `MEERKAT_GATE_LOCK_TIMEOUT` seconds (default 3600). Each slot is a `lockf` lock on a file in `meerkat-gate-lock` in the git common dir, held on the gate's fd 9, which the kernel frees when the gate exits, however it exits. The gate runs its checks in a subshell that closes fd 9 first, so a command that outlives it does not hold the slot.

`bump-deps.sh` bumps non-exempt outdated Hex and JS packages, moving a `~>` requirement in `mix.exs` to latest when needed. It skips a Hex release under 24h old and a JS release pnpm refuses under the 24h minimum release age. It refuses the commit when installing the locked dependencies would change a lockfile, it cannot rewrite a requirement, pnpm fails to resolve a JS release for any other reason, or an update fails. Then `scripts/age-excludes.ts prune` drops each `minimumReleaseAgeExclude` entry that is 24h old, `scripts/advisory-fixes.ts` updates each Hex or JS package an audit finds an advisory against, first with the 24h floor in force and, when that does not fix it, with the floor lifted for it, and `scripts/toolchain.ts bump` moves the toolchain pins and action SHAs onto their targets. `bump-deps.sh` never moves git dependencies, and stages changed `mix.exs`, `mix.lock`, `package.json`, `pnpm-lock.yaml`, `pnpm-workspace.yaml`, `assets/package.json`, `.tool-versions`, `.github/toolchain.env` and workflow files into the commit.

`check.sh` skips the checks when nothing is staged or all staged changes are Markdown-only. Otherwise, once it holds a gate slot, it runs these steps in order:

1. `mix deps.get`
2. `bun scripts/hex-audit.ts`
3. `pnpm audit`
4. `pnpm install --frozen-lockfile --ignore-scripts --prefer-offline`
5. `mix compile --warnings-as-errors`
6. `mix format --check-formatted`
7. `mix credo --strict`
8. `bunx biome lint --error-on-warnings`
9. `bash scripts/mix-test.sh`
10. `bun test` in `assets/`
11. `bun test tests/e2e/lib` from the repo root
12. `bun run build` in `assets/`
13. `bunx playwright install --only-shell chromium`
14. `bun run test:e2e`

`check.sh` records the checked contents, ignoring Markdown, through `scripts/checked-trees.sh` when every step passes and the worktree held exactly those contents, with no untracked file, before and after the steps. `check.sh --head` checks HEAD's contents without the Markdown-only skip.

Biome is configured by `biome.json` and lints JS, TS, CSS, and Svelte files, including Svelte templates and styles. Biome warnings and errors fail the check; infos are printed only.

**Pre-push:** `.lefthook/pre-push/pre-push.sh` runs `scripts/no-private-refs.sh` and `scripts/outdated.sh` for pushes that include updates. A push that only deletes refs skips these checks. The script runs both checks so each can report its findings; if either fails, the push is blocked. If both pass, it runs `scripts/verified-push.sh`. `verified-push.sh` first refuses the push if it brings any merge commit that no remote-tracking ref holds; branches take in `main` by rebasing. It then requires `check.sh` and the mutation gate to have recorded each pushed tip's contents: a rebase or cherry-pick makes commits without the pre-commit hook, and a push is the last point git can refuse them. For each record a tip lacks, it runs `check.sh --head`, then `mutate.sh changed` against `origin/main`, stopping at the first failure. It runs them on an unrecorded HEAD when the worktree holds exactly HEAD, with no untracked file. It refuses the push if that run fails or records nothing. It refuses any other unrecorded HEAD. It runs them on an unrecorded tip other than HEAD in a temporary worktree of that tip. It refuses the push if the run fails or records nothing. It refuses any tip git cannot read. `no-private-refs.sh` reads private patterns, one extended regex per line, from the untracked `info/private-refs` in the git common dir and refuses the push if that file is missing or any pattern fails its self-test. It scans commits not already held by the target remote, plus every pushed tip’s full tree, pushed annotated tags, and pushed ref names, rejecting private-pattern matches, Claude Code session URLs, local absolute paths, and all email addresses except placeholder and no-reply addresses. It refuses the push if the remote cannot be queried.

**CI:** Every PR installs the pinned toolchain: Bun, Erlang and Elixir from `.tool-versions`; pnpm from `package.json`'s `packageManager`; and Hex, rebar3, clj-kondo, PlantUML's native binary, and GNU bash and Graphviz built by `scripts/build-tool.ts`, from `.github/toolchain.env`, checking rebar3, clj-kondo, PlantUML, GNU bash and Graphviz against their pinned SHA-256s. It then runs, in order, `mix deps.get`, `bun scripts/hex-audit.ts`, `pnpm audit`, `pnpm install --frozen-lockfile --ignore-scripts`, `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `bunx biome lint --error-on-warnings`, `bash scripts/mix-test.sh`, `bun test` in `assets/`, `bun test tests/e2e/lib` from the repo root, `bunx playwright install --only-shell chromium`, and `bun run test:e2e`. The Playwright suite's global setup (`tests/e2e/lib/setup.ts`) builds the assets by running `bin/meerkat-beam` with `MEERKAT_BUILD_ONLY=1`. CI runs these checks even when the local hooks skip them.

`scripts/hex-audit.ts` runs `mix hex.audit` and also fails when Hex could not fetch a package's record from hex.pm, since Hex then audits its cache, or nothing, and passes. `pnpm audit` audits every JS dependency, dev ones included, and fails when it cannot reach the npm registry. `check.sh` runs both audits as CI does, so it fails a commit when either registry is out of reach.

**Daily audit:** `.github/workflows/audit.yml` runs `mix deps.get`, `bun scripts/hex-audit.ts` and `pnpm audit` daily on `main`, and on demand on any branch through `workflow_dispatch`, so an advisory published on a day without commits fails a run on `main`. It opens no issues.

`scripts/mix-test.sh` runs each test file in its own BEAM, half the online cores' worth at once. Before its BEAM starts, each file takes one of half the online cores' worth of test-file slots, which all runs in all worktrees of the repo share, so two gates at once run no more test files together than one does. The slots work like the gate slots, from the same `scripts/gate-lock.sh`, in `meerkat-gate-lock/files`, except that a file takes a free slot without a ticket while no file waits, and waits silently. Each test BEAM gets `+S 4 +sbwt none` (four schedulers, no busy-waiting) ahead of any `ELIXIR_ERL_OPTIONS` already set. It times each file's BEAM in whole seconds of wall time, from when the file holds its slot. A file that takes longer than the limit in `scripts/test-file-limit.json` (60 s), has no entry there with a non-empty `reason`, and passed, is run again once every file has finished, one such file at a time, so the run's own other files no longer slow it. The run fails when that second run also takes longer than the limit, or fails. A missing or malformed limits file, or an entry without a reason, fails it too. The pre-commit gate and CI enforce the same limit.

`bun run test` runs `scripts/mix-test.sh`, then `bun test` in `assets/`, then `bun test tests/e2e/lib` from the repo root, then `bun run test:e2e`.

When behaviour changes, choose the lowest layer that exercises it:
- Use ExUnit (`test/**/*_test.exs`, including LiveViewTest) or asset
  `bun test` for behaviour they can reach.
- Use Playwright (`tests/e2e/*.spec.ts`) only for seams those tests
  cannot reach, 1-3 tests per seam: browser Svelte/JS to LiveView,
  CLI to BEAM exit/stdout, and process lifecycle.
- Keep owned/local behaviour real; mock only boundaries we don't own.
- Keep unit tests fast. Never wait out a timeout to show that something
  did not happen: check what is already known, such as a mailbox a
  synchronous call has filled, or wait for the event that settles it.
  Split or speed up a test file before it nears the per-file limit, and
  list a file in `scripts/test-file-limit.json` only with a reason.
- In e2e, read state an observer or `requestAnimationFrame` sets only
  through a retrying assertion or after `afterNextFrame`: CI renders late.

## Mutation testing

`scripts/mutate.sh` runs muex to test whether ExUnit tests detect mutations. With no argument, it mutates every line of every `lib/meerkat/*.ex` file except `lib/meerkat/application.ex` and is slow. `changed` mutates only changed lines in `lib/**/*.ex` relative to the merge base with `origin/main` (`BASE_BRANCH` overrides the base), including uncommitted edits. `staged` mutates only `lib/**/*.ex` lines staged for the next commit; the pre-commit hook uses this mode. It exits 0 immediately when no matching lines are staged. Otherwise it waits for a gate slot and adds minutes to the commit. A staged file with unstaged edits blocks the commit. A surviving mutant or one reported as `no_coverage` (no ExUnit test executes its line) blocks the commit; each is reported with its file, line, status, and code change. muex gives up on a mutant's tests, reporting it timed out, after five minutes without output, because a loaded machine can keep a test BEAM silent for most of a minute while it boots. A test that hangs fails first at ExUnit's per-test timeout, which is shorter, and that failure kills its mutant. A timed-out mutant was judged by no test, so it also blocks the commit and is listed the same way, under its own heading; rerun once the machine is less loaded. Staged lines that produce no mutants pass. When `staged` passes, it records the commit's contents, ignoring Markdown, through `scripts/checked-trees.sh --mutated`, but only when the worktree held exactly those contents, with no untracked file, before and after the run, and HEAD's contents were recorded the same way, HEAD is an ancestor of `origin/main`, or there is no HEAD. A run that mutates lines with extra muex flags records nothing. `changed` waits for a gate slot when it has lines to mutate, judges them as `staged` does and fails the same way. When it passes against `origin/main` and the worktree held exactly HEAD before and after the run, it records HEAD's contents the same way. One or more file paths mutate every line of those files. The default and file-path modes judge their mutants as `staged` does and fail the same way, without a gate slot or a record. It refuses a named path that is not an existing `lib/**/*.ex` file named relative to the repo root. Put extra muex flags after `--`.

```bash
scripts/mutate.sh
scripts/mutate.sh changed
scripts/mutate.sh staged
scripts/mutate.sh lib/meerkat/git.ex
scripts/mutate.sh changed -- --concurrency 4
```

`mix muex --coverage-guided` runs each mutant against the test files
that execute its line.
To learn which those are, it first runs every test file it is given
under `:cover`, however few lines are mutated.
`mutate.sh` gives it every `test/**/*_test.exs` file outside
`test/scripts`.
The `test/scripts` files drive shell scripts in subprocesses, so in
their own BEAM they execute only the app-start lines every test file
executes; leaving them out roughly halves the mutation gate.
Put a test that calls `lib/` code directly, not through a subprocess,
outside `test/scripts`.
A mutant on a line no test executes is skipped as `no_coverage`.
For a line `:cover` has no entry for, such as a `def` header, muex
falls back to dependency analysis and then to every test file it was given.
A mutant is a survivor when the test files run for its line still
pass against it.

Every blocking mutant must be killed by a test in the same commit, except for the kinds listed under “Acceptable non-fixes” below: equivalent mutants, pure-observability mutations, and unreachable I/O seams. For one of these exceptions, put a `# muex:ignore <reason>` comment on its own line directly above the mutated line, in a position that `mix format` leaves in place, with a reason explaining why it qualifies; muex reports every mutant on the line below an annotated comment as ignored, so none blocks the commit, whatever its status would otherwise have been. Do not use this comment for any other survivor. Never bypass the hook with `--no-verify`.

### Fix every surviving mutant

Do not dismiss surviving mutants under ordinary review triage.
Fix each survivor with a test or document it under an acceptable
non-fix below.
This repository is under our end-to-end control.
It has no external reviewers, legacy callers, or compatibility
constraints.
A surviving mutant is a real gap even when its code predates the PR.
Fix it now.
Closing an unrelated test gap is worthwhile.

For a pure-logic survivor, add a test that rejects the behavior
introduced by the mutation.
If logic is buried in I/O-bound or server-bound code, extract it
behind a test seam.
Test the extracted pure logic.

`mix muex` runs ExUnit only.
It cannot see Playwright e2e coverage.
Fix or document every survivor under the rules below.

### Acceptable non-fixes

An equivalent mutant is acceptable only when no input, realistic or
otherwise, distinguishes it from the original.
Document why it is equivalent.
Do not remove a real safety guard just to remove a mutation point.

A pure-observability non-fix is allowed only when the mutation changes
log or `IO.puts` message text.

An unreachable I/O seam is an acceptable non-fix only when ExUnit
cannot reach the code.
Explain why ExUnit cannot reach it.
Name the e2e test that kills the mutant.

## Review and merge

The `/pull-requests:review-and-merge` skill runs the merge-time checks and
post-merge steps in this section.

### Mutation-test the PR

Run the check on every changed `lib/**/*.ex` file in the PR.

```bash
set -euo pipefail

CHANGED=$(git diff --name-only --diff-filter=d <base>...HEAD -- 'lib/*.ex')
if [ -z "$CHANGED" ]; then
  echo "No changed lib/**/*.ex files; skipping mutation testing."
else
  scripts/mutate.sh $CHANGED
fi
```

Run `git fetch origin` before the check.
Use the PR's base branch on the refreshed `origin` as `<base>`, on
reruns after fix commits too, so a fix that only adds tests still
re-checks the files whose mutants it targets.
The PR branch must be checked out for this command.
The `lib/*.ex` pathspec matches `.ex` files at any depth under `lib/`.
The `--diff-filter=d` option omits deleted files.
This keeps deleted paths out of the file list passed to muex.
With `set -euo pipefail`, a failing `git diff` aborts instead of
producing an empty list.
The empty-list guard prevents an empty file list from invoking the
default mutation scope.

### Post-merge deploy

After the plugin updates local `main` successfully, deploy from this
session's own worktree.

`git fetch` fires no hook.
A pull that moves `main` fires `post-merge`.
A pull that changes nothing fires no hook.
When the hook runs on `main`, it invokes `install.sh` in that worktree.
The hook may deploy a `-wip` build if `git status --porcelain`
prints anything.

Use only this session's own worktree for the explicit deploy.
Leave it on `main` if it already has `main` checked out.
Otherwise, require `git status --porcelain` to print nothing before
running `git switch --detach main`.
If the switch fails, report that deployment was skipped and why.

A worktree is clean only when `git status --porcelain` prints
nothing.
Untracked non-ignored files make the worktree dirty.
If the worktree is dirty, do not run the installer.
Report why deployment was skipped.
After the worktree is on the updated local `main` and is clean, run
`bash scripts/install.sh` there.

Check the first 12 characters of that worktree's `HEAD`.
An explicit install succeeds only when it exits with code 0.
For a new build, the output must include
`meerkat: built version <id> at <path>`.
The `<id>` must start with the expected 12-character prefix.
The `<id>` must contain no `-wip`.
The output must end with `meerkat: done.`.
An up-to-date build succeeds when it prints
`meerkat: current already built from <prefix> (clean tree); skipping. Pass --force to rebuild.`.
The prefix in that line must match the expected 12 characters.
Any other outcome is a deployment failure.
Report any deployment failure.
If a pull hook or explicit install ran and the clean install did not
succeed, report that a `-wip` build may be live.

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

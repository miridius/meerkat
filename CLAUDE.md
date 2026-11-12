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
  hook bumps registry packages, and the post-rewrite hook does after a
  rebase; do not bump them by hand. Neither ever
  moves git dependencies, so maintain
  their pins by hand. Fix fallout rather than pinning old
  releases. Each `scripts/dep-exemptions.json` entry needs a `version`
  and non-empty `reason`; missing or malformed files and stale entries
  fail the gate. Before reading their reports, the gate and the bump
  install the locked dependencies, and fail when that would change
  `mix.lock` or `pnpm-lock.yaml`. The gate fails closed.
  The toolchain is held to the same floor: `scripts/toolchain.ts`
  fails the gate when a pin in `.tool-versions` or
  `.github/toolchain.env`, `package.json`'s `packageManager`, or an
  action SHA in a workflow or `.github/actions/toolchain` is not the
  newest release at least 24h old, and the pre-commit hook bumps them.
  The one exception is a security fix: when a published advisory
  affects a dependency's current version, or a tool's newest release
  24h old, the release that fixes
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
- **No demo data.** The review UI runs against real diffs.
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
   test that fails before the fix: the smallest test that catches
   it. Tests pass `--no-open`.
   A run that needs a browser (Playwright, `meerkat-qa`) opens the
   printed URL itself.
3. **Ship.** Commit and push without asking first.
   `main` is branch-protected on GitHub — no direct pushes, no
   force-pushes; changes land via PR.

## Quality gates

**Pre-commit:** Lefthook runs `scripts/no-main-commits.ts`, `scripts/bump-deps.sh`, `scripts/check.ts`, then `scripts/mutate.ts staged`. They are piped, so if one script refuses the commit, later scripts do not run. Lefthook prints their output as it comes.

**Gate slots:** At most two gates in all worktrees of the repo run their checks at once. `check.ts`, in either mode, and `mutate.ts staged` or `changed` each take one of two slots from `scripts/gate-lock.sh`, through `scripts/gate-run.sh`, before their checks and free it when they end. A gate that finds both slots taken, or other gates waiting ahead of it, prints that it is waiting. Gates take slots first come, first served: each takes a ticket named for the time it started waiting, a file in `meerkat-gate-lock/waiting` that it holds a `lockf` lock on, and only the gate with the earliest live ticket tries the slots, so no gate is overtaken by one that started waiting later. Under bash before 5 a ticket is named for the start of its second, so such a gate can overtake one that started earlier in that second. A ticket whose gate died is unlocked; the next gate to find it deletes it. Gates on the script from before tickets wait for a lock on `meerkat-gate-lock/queue` instead. The gate with the earliest ticket takes that lock when it is free and holds it until it gets a slot, stops being the earliest, or gives up; while one of those gates holds it, the two race for the slots. A waiting gate tries the locks once a second rather than blocking, since `lockf` blocked on an fd spins a core, and gives up, failing the gate, after `MEERKAT_GATE_LOCK_TIMEOUT` seconds (default 3600). Each slot is a `lockf` lock on a file in `meerkat-gate-lock` in the git common dir, held on the gate's fd 9, which the kernel frees when the gate exits, however it exits. The gate runs its checks in a subshell that closes fd 9 first, so a command that outlives it does not hold the slot.

`bump-deps.sh` bumps non-exempt outdated Hex and JS packages, moving a `~>` requirement in `mix.exs` to latest when needed. It skips a Hex release under 24h old and a JS release pnpm refuses under the 24h minimum release age. It refuses the commit when installing the locked dependencies would change a lockfile, it cannot rewrite a requirement, pnpm fails to resolve a JS release for any other reason, or an update fails. Then `scripts/age-excludes.ts prune` drops each `minimumReleaseAgeExclude` entry that is 24h old, `scripts/advisory-fixes.ts` updates each Hex or JS package an audit finds an advisory against, first with the 24h floor in force and, when that does not fix it, with the floor lifted for it, and `scripts/toolchain.ts bump` moves the toolchain pins and action SHAs onto their targets. Then `scripts/setup-toolchain.ts` installs, through mise, any pinned Erlang, Elixir or Bun still missing, and the pinned Hex and rebar3 into the pinned Elixir. `bump-deps.sh` never moves git dependencies, and stages changed `mix.exs`, `mix.lock`, `package.json`, `pnpm-lock.yaml`, `pnpm-workspace.yaml`, `assets/package.json`, `.tool-versions`, `.github/toolchain.env`, workflow files and `.github/actions/toolchain/action.yml` into the commit.

`check.ts` skips the checks when nothing is staged or all staged changes are Markdown-only. Otherwise, once it holds a gate slot, it runs these steps in order:

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
12. `bun test scripts` from the repo root
13. `bun run build` in `assets/`
14. `bunx playwright install --only-shell chromium`
15. `bun run test:e2e`

`check.ts` skips steps 13-15 when no staged path is an e2e input. `scripts/e2e-inputs.ts` holds an allowlist of paths nothing in the e2e run reads or executes, leaving out itself, such as `test/` other than `test/support/test.gitconfig`, `scripts/` other than `check.ts` and `e2e-inputs.ts`, `.github/` other than `toolchain.env`, and `.claude/`; every other path, new ones included, is an e2e input. A test fails if a repo path that a quoted string containing `/` in `playwright.config.ts` or `tests/e2e/` names lands on the allowlist.

`check.ts` records the checked contents, ignoring Markdown, through `scripts/checked-trees.ts` when every step passes and the worktree held exactly those contents, with no untracked file, before and after the steps. When steps 13-15 ran, it also records the contents' e2e inputs through `scripts/checked-trees.ts --e2e`. When it skipped them, it records the contents as checked only if their e2e inputs were recorded that way, as they are when HEAD's contents passed every step here and were recorded; otherwise the pre-push check runs every step on a pushed tip that holds them. `check.ts --head` checks HEAD's contents without either skip.

Biome is configured by `biome.json` and lints JS, TS, CSS, and Svelte files, including Svelte templates and styles. Biome warnings and errors fail the check; infos are printed only.

**Post-rewrite:** After a rebase, `scripts/rebase-bump.ts` bumps outdated dependencies and commits the bump on top, automatically; a rebased branch needs nothing done about them.

**Pre-push:** `.lefthook/pre-push/pre-push.sh` runs `scripts/no-private-refs.sh` and `scripts/outdated.sh` for pushes that include updates. A push that only deletes refs skips these checks. The script runs both checks so each can report its findings; if either fails, the push is blocked. If both pass, it runs `scripts/verified-push.ts`. `verified-push.ts` first refuses the push if it brings any merge commit that no remote-tracking ref holds; branches take in `main` by rebasing. It then requires `check.ts` and the mutation gate to have recorded each pushed tip's contents: a rebase or cherry-pick makes commits without the pre-commit hook, and a push is the last point git can refuse them. For each record a tip lacks, it runs `check.ts --head`, then `mutate.ts changed` against `origin/main`, stopping at the first failure. It runs them on an unrecorded HEAD when the worktree holds exactly HEAD, with no untracked file. It refuses the push if that run fails or records nothing. It refuses any other unrecorded HEAD. It runs them on an unrecorded tip other than HEAD in a temporary worktree of that tip. It refuses the push if the run fails or records nothing. It refuses any tip git cannot read. `no-private-refs.sh` reads private patterns, one extended regex per line, from the untracked `info/private-refs` in the git common dir and refuses the push if that file is missing or any pattern fails its self-test. It scans commits not already held by the target remote, plus every pushed tip’s full tree, pushed annotated tags, and pushed ref names, rejecting private-pattern matches, Claude Code session URLs, local absolute paths, and all email addresses except placeholder and no-reply addresses. It refuses the push if the remote cannot be queried.

**CI:** Every PR installs the pinned toolchain: Bun, Erlang and Elixir from `.tool-versions`; pnpm from `package.json`'s `packageManager`; and Hex, rebar3, clj-kondo, PlantUML's native binary, and GNU bash and Graphviz built by `scripts/build-tool.ts`, from `.github/toolchain.env`, checking rebar3, clj-kondo, PlantUML, GNU bash and Graphviz against their pinned SHA-256s. Every tool but pnpm, and Playwright's Chromium shell, is cached per pin, so a run whose pins are all cached downloads none of them. It then runs, in order, `mix deps.get`, `bun scripts/hex-audit.ts`, `pnpm audit`, `pnpm install --frozen-lockfile --ignore-scripts`, `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `bunx biome lint --error-on-warnings`, `bash scripts/mix-test.sh`, `bun test` in `assets/`, `bun test tests/e2e/lib` and `bun test scripts` from the repo root, `bunx playwright install --only-shell chromium` when its cache misses, and `bun run test:e2e`. The Playwright suite's global setup (`tests/e2e/lib/setup.ts`) builds the assets by running `bin/meerkat-beam` with `MEERKAT_BUILD_ONLY=1`. CI runs these checks even when the local hooks skip them.

`scripts/hex-audit.ts` runs `mix hex.audit` and also fails when Hex could not fetch a package's record from hex.pm, since Hex then audits its cache, or nothing, and passes. `pnpm audit` audits every JS dependency, dev ones included, skips the advisories `pnpm-workspace.yaml`'s `auditConfig.ignoreGhsas` lists, and fails when it cannot reach the npm registry. `check.ts` runs both audits as CI does, so it fails a commit when either registry is out of reach.

**Daily audit:** `.github/workflows/audit.yml` runs `mix deps.get`, `bun scripts/hex-audit.ts` and `pnpm audit` daily on `main`, and on demand on any branch through `workflow_dispatch`, so an advisory published on a day without commits fails a run on `main`. It caches its tools as CI does, and opens no issues.

`scripts/mix-test.sh` runs each test file in its own BEAM, at most half the online cores' worth at once across all test runs in all worktrees of the repo. Each test BEAM gets `+S 4 +sbwt none` (four schedulers, no busy-waiting) ahead of any `ELIXIR_ERL_OPTIONS` already set. When every file passes, each one over the limit in `scripts/test-file-limit.json` without an entry there giving a non-empty `reason` is run again, one at a time, and fails the run if it is still over or then fails; a missing or malformed limits file, or an entry without a reason, fails it too. Locally the limit is 10 s of CPU time, which leaves out programs the test BEAM starts; in CI (`CI=true`), 60 s of wall time.

`bun run test` runs `scripts/mix-test.sh`, then `bun test` in `assets/`, then `bun test tests/e2e/lib` and `bun test scripts` from the repo root, then `bun run test:e2e`.

When behaviour changes, always use the smallest test that works:
- Test each piece's logic in a unit test: ExUnit
  (`test/**/*_test.exs`, including LiveViewTest) or asset `bun test`,
  given literal inputs or stand-ins for the pieces it uses, such as git.
- Add only the integration and e2e tests needed to show the pieces fit
  together, for example one integration test per seam, such as CLI to
  BEAM exit/stdout, process lifecycle, or browser Svelte/JS to LiveView
  (which only Playwright reaches), and one Playwright test
  (`tests/e2e/*.spec.ts`) per major feature.
- Keep unit tests fast. Never wait out a timeout to show that something
  did not happen: check what is already known, such as a mailbox a
  synchronous call has filled, or wait for the event that settles it.
  Split or speed up a test file before it nears the per-file limit, and
  list a file in `scripts/test-file-limit.json` only with a reason.
- In e2e, read state an observer or `requestAnimationFrame` sets only
  through a retrying assertion or after `afterNextFrame`: CI renders late.
- In e2e, give a timeout its idle-machine value through `budget`
  (`tests/e2e/lib/budget.ts`), which stretches it for a loaded machine.

## Mutation testing

`scripts/mutate.ts` runs muex to test whether ExUnit tests detect mutations. With no argument, it mutates every line of every `lib/meerkat/*.ex` file except `lib/meerkat/application.ex` and is slow. `changed` mutates only changed lines in `lib/**/*.ex` relative to the merge base with `origin/main` (`BASE_BRANCH` overrides the base), including uncommitted edits. `staged` mutates only `lib/**/*.ex` lines staged for the next commit; the pre-commit hook uses this mode. It exits 0 immediately when no matching lines are staged. Otherwise it waits for a gate slot and adds minutes to the commit. A staged file with unstaged edits blocks the commit. A surviving mutant or one reported as `no_coverage` (no ExUnit test executes its line) blocks the commit; each is reported with its file, line, status, and code change. muex gives up on a mutant's tests, reporting it timed out, once ExUnit has run them for 15 minutes, counted from the suite's start, or when booting and compiling take 90 minutes. A test that hangs fails first at ExUnit's per-test timeout, which is far shorter than the whole suite's bound, and that failure kills its mutant. A timed-out mutant was judged by no test, so it also blocks the commit and is listed the same way, under its own heading; rerun once the machine is less loaded. Staged lines that produce no mutants pass. When `staged` passes, it records the commit's contents, ignoring Markdown, through `scripts/checked-trees.ts --mutated`, but only when the worktree held exactly those contents, with no untracked file, before and after the run, and HEAD's contents were recorded the same way, HEAD is an ancestor of `origin/main`, or there is no HEAD. A run that mutates lines with extra muex flags records nothing. `changed` waits for a gate slot when it has lines to mutate, judges them as `staged` does and fails the same way. When it passes against `origin/main` and the worktree held exactly HEAD before and after the run, it records HEAD's contents the same way. One or more file paths mutate every line of those files. The default and file-path modes judge their mutants as `staged` does and fail the same way, without a gate slot or a record. It refuses a named path that is not an existing `lib/**/*.ex` file named relative to the repo root. Put extra muex flags after `--`.

```bash
bun scripts/mutate.ts
bun scripts/mutate.ts changed
bun scripts/mutate.ts staged
bun scripts/mutate.ts lib/meerkat/git.ex
bun scripts/mutate.ts changed -- --concurrency 4
```

`mix muex --coverage-guided` runs each mutant against the test files
that execute its line.
To learn which those are, it first runs every test file it is given
under `:cover`, however few lines are mutated.
`mutate.ts` gives it every `test/**/*_test.exs` file outside
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

Mutate only the lines the PR changes, never whole files:

```bash
git fetch origin
BASE_BRANCH=origin/<base> bun scripts/mutate.ts changed
```

Use the PR's base branch as `<base>`, on reruns after fix commits too,
so a fix that only adds tests still re-checks the lines it targets.
The PR branch must be checked out for this command.

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

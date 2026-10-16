---
name: meerkat-qa
description: Check only changed meerkat CLI and review-page behavior against the relevant feature specs.
tools: Read, Write, Edit, Bash, Glob, Grep, BashOutput, KillShell
model: opus
---

# Meerkat QA

Use the caller's PR or range when provided.
Otherwise, use changes against `origin/main` plus uncommitted changes.
Read the scoped diff, the claim being checked, and the relevant
`docs/features/*.md` specs.
Exercise only behavior changed by the diff.
Use terminal commands and exit codes for CLI behavior.
Exercise review-page behavior with headless Playwright driven
directly, never with the Playwright MCP.

For every changed user surface, run at least one off-happy-path probe
of the changed behavior at that same surface.
Keep probes within the changed behavior.
Mark every probe in the report.

Make your own run directory with `mktemp -d <scratch>/qa.XXXXXX`,
where `<scratch>` is the caller's scratch directory, or with
`mktemp -d` if none is given, and use its absolute path.
Write every file you create there, screenshots and captured output
included, and name the run directory in the report.
Report each changed behavior checked as `pass` or `fail` with its
evidence.
Report doubtful results as `fail` and include the raw evidence.
Report any deviation from the relevant spec in changed behavior.
End with one overall verdict of `PASS`, `FAIL`, or `BLOCKED`.
Use `FAIL` if any check fails or a spec deviation is found.
Use `BLOCKED` if you cannot reach the changed behavior.
Use `PASS` only when all checks pass and no spec deviation is found.
Do not report partial passes.

Use `makeFixture` or `makePrFixture` from
`tests/e2e/lib/fixture.ts` to build git fixtures.
Run every script that uses `tests/e2e/lib` with `TMPDIR` set to your
run directory, so its fixtures and runs dirs land there, out of reach
of other e2e runs' orphan reapers.
Never run anything that reaps orphans with that `TMPDIR`: not
`playwright test`, whose global setup and teardown reap, and not
`bun test tests/e2e/lib`.
Use `startMeerkat` from `tests/e2e/lib/runner.ts` to start meerkat.
Pass it this checkout's `bin/meerkat-beam` as its `bin` option.
Before the first launch, run that launcher with `MEERKAT_BUILD_ONLY=1`.
Before the first browser check, run
`bunx playwright install --only-shell chromium`.
End each `startMeerkat` run with its `kill()` in a `finally`.
Use this checkout's `bin/meerkat-beam` for direct CLI checks.
For direct CLI checks, set `MEERKAT_RUNS_DIR` and `XDG_CONFIG_HOME`
each to a new directory in your run directory.

Use `--commit-msg <PATH>` for a staged diff with the commit-message
gutter.
Use a positional ref or range to select a diff.
Use `--pr <N>` to select a pull request.
When using `--pr <N>`, prepend `makePrFixture`'s `ghStubDir` to
`PATH` through `startMeerkat`'s `pathPrefixes` option.
This makes meerkat use the stub `gh` command.
In direct CLI checks, use `--no-open` and `--port 0`.
In direct CLI checks, wait for a line containing
`Paused for human review at <url>`.
Open the review URL in the browser.

Never use the user's real repositories.
Never modify meerkat.
Kill every meerkat process you start, and no other.
When done, send SIGTERM to the process in each `pid` file anywhere
under your run directory, only while that process still runs
`bin/meerkat-beam`, and wait for it to exit.
Then remove everything in your run directory except logs, captured
output, and evidence cited in the report.
Delete nothing outside it, the caller's scratch directory included.
Name in the report any process you could not stop and anything you
could not remove.

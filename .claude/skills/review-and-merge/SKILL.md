---
name: review-and-merge
description: Shepherd a GitHub PR through review-to-merge. Runs /pr-review-toolkit:review-pr, triages the findings, verifies the ones worth fixing by running them, lands fixes on the PR's branch, mutation-tests the changed Elixir, and squash-merges. INVOKE THIS whenever the user asks to "review and merge PR #N", "review this PR", "finish this PR", or points at a specific PR they want taken end-to-end — even if they don't say "merge".
---

# Review and merge a PR

1. Run `/pr-review-toolkit:review-pr` on the PR.
2. Discard findings that are not worth fixing, detrimental to our goals, or would make the code worse. A finding kept past this step MUST be addressed on this PR's branch before merge — see "No follow-up PRs" below.
3. Verify the remaining findings empirically — run the code, don't just read it — and fix the accurate ones on the PR's branch.
4. Anything debatable on accuracy or actionability → `/escalate` with concrete options.
5. **Run mutation testing** on the Elixir files the PR changed (see "Mutation testing" below). Treat each surviving mutant as a finding subject to the same triage as steps 2-4: fix on this branch (add a test that kills it), escalate, or discard at step 2 with a recorded reason. No follow-ups. (The Playwright e2e suite has no mutation tooling; a PR that only touches `tests/e2e/` or `assets/` skips this step.)
6. Squash-merge on GitHub once every kept finding (including surviving mutants) is resolved on this PR's branch and the quality gates ran clean from the branch tip. **There is no separate CI gate; the review IS the check.** The gates are `mix compile --warnings-as-errors`, `mix test`, and `bun run test:e2e`. The lefthook pre-commit hook runs `bash scripts/check.sh` (format-check + compile) and the pre-push hook runs `mix test`, so fix commits in steps 3/5 exercise those on `git commit` / `git push` — but the e2e suite is in no hook, so run `bun run test:e2e` yourself before merging. If no fix commits were needed, run all three gates yourself.

## Guardrails

- Never push, rebase, or update PRs without explicit permission. Invoking this skill counts as permission to push fix commits to the PR's branch and squash-merge; nothing broader.
- Fix commits go on the PR's branch. Never commit to `main` — `scripts/no-main-commits.sh` blocks this; don't bypass with `--no-verify`.
- Squash-merge via GitHub (`gh pr merge --squash --delete-branch`). Never merge locally bypassing GitHub.

## No follow-up PRs

**NEVER defer a kept finding to a follow-up PR, follow-up commit, follow-up issue, or "next iteration".** Phrases like "edge case, follow-up", "low priority, separate PR", "out of scope for this PR", "land in a follow-up", "leave as a TODO" are all forbidden at any step before the squash-merge (this applies to both static-review findings from step 1 and mutation findings from step 5). The set of acceptable post-triage outcomes for any finding is exactly:

- **Fix it on this branch now** (step 3), or
- **Escalate via step 4** (the user picks: fix now, drop the finding, or change direction), or
- **Already fixed** (the finding was outdated or the code already handles it — verify empirically before declaring this).

If a finding is worth fixing later, it's worth fixing now. If it isn't worth fixing now, it should have been discarded at step 2 with a recorded reason — not kept and deferred. There is no "later" that isn't this PR.

## Mutation testing

Static review (step 1) only catches what the review agents notice from reading the diff. Mutation testing catches the test-coverage gaps it misses — places where the suite passes even when the code is subtly wrong. `mix muex` (wrapped by `scripts/mutate.sh`) rewrites operators / literals one at a time and re-runs the suite; a rewrite the suite still passes against is a **surviving mutant** = a test gap. Run it on the files the PR actually changed.

```bash
set -euo pipefail

# Scope to the Elixir source files the PR changed, under lib/. mutate.sh
# accepts explicit paths; passing them scopes the run to exactly the PR's
# files (a bare `scripts/mutate.sh` mutates all of lib/meerkat/*.ex —
# hours, not minutes).
CHANGED=$(gh pr diff <PR#> --name-only | { grep '^lib/.*\.ex$' || true; })
if [ -z "$CHANGED" ]; then
  echo "No lib/*.ex files changed by this PR — skipping mutation testing."
else
  scripts/mutate.sh $CHANGED
fi
```

Two load-bearing details:

- **`set -euo pipefail`** so a `gh pr diff` failure (auth, wrong PR#) aborts instead of silently leaving `$CHANGED` empty and skipping the step.
- **Empty-`$CHANGED` guard**: a PR that only touches `tests/`, `tests/e2e/`, `assets/`, or config has no Elixir source to mutate — skip the step, don't run the full suite.

Mutation runs take minutes per module. `scripts/mutate.sh` prints the survivor list to read by hand.

### Triage surviving mutants

- **Mutant on a line the PR introduced or modified** → kept finding; address per the no-follow-up rule. The fix is usually a new test that asserts the post-mutation behaviour would be wrong (e.g. for a guard mutated to always-true, add a case that must return false). Where the mutated code is reachable only via an unbounded-await path (server start, browser-driven flow), test at a lower layer rather than refactoring production code purely for testability.
- **Mutant on a line the PR didn't touch** → pre-existing gap; discard with reason "pre-existing scope; not made worse by this PR." Do NOT widen the PR to fix pre-existing coverage unless the user directs it.

### Discard reasons that are acceptable

- "Pre-existing line, PR didn't touch it" (most common).
- "Mutation affects observability strings only (log/`IO.puts` message text, eprintln branch selection) — no behavioral correctness depends on the exact string." Document the discard.
- "Mutation in a path requiring infeasible test infrastructure (end-to-end browser drive, libgit2 internal-error reproduction). Test at a lower layer where reachable; otherwise refactoring purely for testability is disproportionate to the regression surface."

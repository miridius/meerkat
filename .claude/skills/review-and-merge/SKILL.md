---
name: review-and-merge
description: Shepherd a GitHub PR through review-to-merge. Runs /pr-review-toolkit:review-pr, triages the findings, verifies the ones worth fixing by running them, lands fixes on the PR's branch, mutation-tests the changed Elixir, and squash-merges. INVOKE THIS whenever the user asks to "review and merge PR #N", "review this PR", "finish this PR", or points at a specific PR they want taken end-to-end — even if they don't say "merge".
---

# Review and merge a PR

1. Run `git fetch origin main`, rebase the PR's branch onto
   `origin/main`, and push the rebased branch with
   `git push --force-with-lease`. Then run
   `/pr-review-toolkit:review-pr` on the PR.
2. Discard findings that are not worth fixing, detrimental to our goals, or would make the code worse. A finding kept past this step MUST be addressed on this PR's branch before merge — see "No follow-up PRs" below.
3. Verify the remaining findings empirically — run the code, don't just read it — and fix the accurate ones on the PR's branch.
4. Anything debatable on accuracy or actionability → raise it to the user as a question with concrete options, then wait for the answer.
5. **Run mutation testing** on the Elixir files the PR changed (see "Mutation testing" below). Every surviving mutant gets fixed on this branch (a test that kills it) or escalated — no discarding, no "pre-existing" pass (see "Fix every surviving mutant"). The only exceptions are provably-equivalent mutants and pure-observability mutations, each documented. No follow-ups. (The Playwright e2e suite has no mutation tooling; a PR that only touches `tests/e2e/` or `assets/` skips this step.)
6. Once every kept finding (including surviving mutants) is resolved on this PR's branch and CI is green on the branch tip, run `git fetch origin main` and check whether the PR's branch is behind `origin/main`. If it is, rebase it onto `origin/main`, push it with `git push --force-with-lease`, wait for CI to be green on the new tip, then fetch `origin/main` again and check whether the branch is behind. Repeat the rebase, push, and CI cycle whenever it is behind. Stop only when CI is green on the branch tip and the branch is not behind the latest fetched `origin/main`; then mark a draft PR ready with `gh pr ready <N>` and squash-merge it on GitHub.
7. **Update and deploy:** As soon as the merge lands, update local `main` with `git fetch origin main:main`. If it refuses because `main` is checked out in a worktree, run `git pull --ff-only` there. Do not assume the merge command updated local `main` or deleted the local PR branch. If local `main` cannot be fast-forwarded, report why and skip deployment; do not reset, stash, or discard anything. Continue to cleanup regardless. `git fetch` fires no hook. A pull that moves `main` fires `post-merge`; a pull that changes nothing fires no hook. When the hook runs, it invokes `install.sh` in that worktree and may deploy a `-wip` build if `git status --porcelain` prints anything. For the final deploy, use **only the session’s own worktree**. If it has `main` checked out, leave it there; otherwise, first require `git status --porcelain` to print nothing, then run `git switch --detach main`. If that switch fails, report that deployment was skipped and why. A worktree is clean only when `git status --porcelain` prints nothing; any output, including untracked non-ignored files, means it is dirty. If the session’s worktree is dirty, do not run the installer; report that deployment was skipped and why. Otherwise, run `bash scripts/install.sh` there. Check the first 12 characters of that worktree’s `HEAD` (the updated local `main` tip). The install succeeds only if it exits 0 and either prints `meerkat: built version <id> at <path>` with `<id>` starting with those 12 characters and containing no `-wip`, then ends with `meerkat: done.`, or prints `meerkat: current already built from <prefix> (clean tree); skipping. Pass --force to rebuild.` with that same prefix. Any other outcome means the deploy failed: report it and continue to cleanup. If any installer ran—the pull hook or explicit install—but the clean install did not succeed, report that a `-wip` build may be live.

   **Cleanup:** Run `git fetch --prune origin` before choosing remote branches. Get merged PR heads with `gh pr list --state merged --limit 1000 --json headRefName,headRefOid`. A branch is dead only if it is not `main`, a merged PR has that branch name as its `headRefName`, and its tip equals that PR’s `headRefOid` or `git merge-base --is-ancestor <tip> <headRefOid>` exits 0. Any non-zero exit means the branch is not dead. Nothing else counts as dead; keep branches of closed, unmerged PRs. Delete matching branches among the remaining `origin/*` refs with `git push origin --delete <branch>...`. If pruning fails, report it and skip remote deletion; if a push fails, report it. In either case, continue with local cleanup. Remove worktrees on dead local branches before deleting those branches locally; use `git worktree remove <path>` without `--force`, then run `git worktree prune`. Never attempt to remove the main worktree/bare-repository root or the session’s own worktree. Never delete a branch checked out in the session’s own worktree. If removal is refused for any reason, leave that worktree and its checked-out branch intact; never unlock a worktree or force its removal. Delete other dead local branches with `git branch -D <branch>` only after their worktrees have been removed and no worktree still has them checked out.

## Guardrails

- Never push, rebase, or update PRs without explicit permission. Invoking this skill counts as permission to rebase the PR's branch onto `origin/main` and push it with `git push --force-with-lease`, push fix commits to the PR's branch, mark it ready for review with `gh pr ready <N>`, and squash-merge it; after a merge, it also authorizes step 7’s `main` update and deployment, and deletion of only the dead branches and worktrees defined there, including pushes to delete qualifying remote branches. Before every push to the PR's branch under this skill, run `git fetch origin main` and rebase that branch onto `origin/main`; use `git push --force-with-lease` to push it. It does not authorize unlocking or force-removing worktrees, or anything broader.
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

`scripts/mutate.sh` prints the survivor list to read by hand.

### Fix every surviving mutant

This is a small, vibe-coded repo we control end-to-end — there are no external
reviewers, no legacy callers, no compat constraints. So there is **no
"pre-existing, not my problem" escape**: a surviving mutant is a real gap
whether or not this PR introduced the line. Fix it now.

For a survivor in **pure logic**, the fix is a test that asserts the
post-mutation behaviour would be wrong (e.g. for a guard mutated to always-true,
add a case that must return false). When the logic is buried in an
I/O-/server-bound function, extract it behind a test seam and unit-test the pure
part — see `cli.ex`'s `decide_from_verdicts/2` and its `*_for_test` shim.

`mix muex` runs ExUnit **only** and is blind to the Playwright e2e suite, and
its `StatementDeletion` mutants on thin I/O glue are unreliable (they survive
even with a direct test, and the score flips between runs as slow mutants
time-out vs survive). So treat the score as a **guide, not a hard gate**: chase
it for pure logic, don't chase it to zero on I/O glue.

### Acceptable non-fixes (prove it, don't assert it)

- **Equivalent mutant** — no input, realistic or not, distinguishes the mutant
  from the original (e.g. an `and`-guard redundant because a downstream call
  already handles the case). Document *why*. Never delete a real safety guard
  just to remove the mutation point.
- **Pure observability** — the mutation only changes log/`IO.puts` message text.
- **I/O wiring already covered end-to-end** — a `StatementDeletion`/conditional
  mutant on thin glue (config assembly, `server_info` parsing, the CLI entry
  point, the staged-files→classify plumbing) whose behaviour the Playwright
  suite already exercises. muex can't see that coverage. Do **not** duplicate it
  in a real-git-fixture ExUnit test — those are redundant with e2e, fight the
  repo's unit-vs-e2e split, and (doing concurrent `git` I/O in an `async` module)
  flake. Name the e2e test that covers it instead.

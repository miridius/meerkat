---
name: review-and-merge
description: Shepherd a GitHub PR through review-to-merge. Runs /pr-review-toolkit:review-pr, triages the findings, verifies the ones worth fixing by running them, lands fixes on the PR's branch, and squash-merges. INVOKE THIS whenever the user asks to "review and merge PR #N", "review this PR", "finish this PR", or points at a specific PR they want taken end-to-end — even if they don't say "merge".
---

# Review and merge a PR

1. Run `/pr-review-toolkit:review-pr` on the PR.
2. Discard findings that are not worth fixing, detrimental to our goals, or would make the code worse. A finding kept past this step MUST be addressed on this PR's branch before merge — see "No follow-up PRs" below.
3. Verify the remaining findings empirically — run the code, don't just read it — and fix the accurate ones on the PR's branch.
4. Anything debatable on accuracy or actionability → `/escalate` with concrete options.
5. Squash-merge on GitHub once every kept finding is resolved on this PR's branch and `bun run check` + `bun run test` both ran clean from the branch tip. **There is no separate CI gate; the review IS the check.** If you made fix commits in step 3, `git commit` / `git push` will fire the lefthook pre-commit/pre-push hooks (which run those scripts). If no fix commits were needed, run `bun run check && bun run test` yourself before merging — lefthook only runs on commit/push.

## Guardrails

- Never push, rebase, or update PRs without explicit permission. Invoking this skill counts as permission to push fix commits to the PR's branch and squash-merge; nothing broader.
- Fix commits go on the PR's branch. Never commit to `main` — `scripts/no-main-commits.sh` blocks this; don't bypass with `--no-verify`.
- Squash-merge via GitHub (`gh pr merge --squash --delete-branch`). Never merge locally bypassing GitHub.

## No follow-up PRs

**NEVER defer a kept finding to a follow-up PR, follow-up commit, follow-up issue, or "next iteration".** Phrases like "edge case, follow-up", "low priority, separate PR", "out of scope for this PR", "land in a follow-up", "leave as a TODO" are all forbidden at step 3 or step 5. The set of acceptable post-triage outcomes for any finding is exactly:

- **Fix it on this branch now** (step 3), or
- **Escalate via step 4** (the user picks: fix now, drop the finding, or change direction), or
- **Already fixed** (the finding was outdated or the code already handles it — verify empirically before declaring this).

If a finding is worth fixing later, it's worth fixing now. If it isn't worth fixing now, it should have been discarded at step 2 with a recorded reason — not kept and deferred. There is no "later" that isn't this PR.

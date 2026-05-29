# Decision flow

The reviewer's verdict produces an exit code that the git-commit
hook (or calling agent) interprets. The decision footer at the
bottom of the review UI is the only path to a terminal state in
normal operation.

## Buttons

The footer always shows three buttons, left-to-right:

1. **Cancel** — abandon the review. Wipes every in-progress
   comment, submits a `:cancel` decision. The BEAM exits **1** and
   prints `Review cancelled — commit aborted, no feedback to act
   on.` to stderr (the comments were wiped, so there's no feedback
   payload — just the verdict line). Use when the reviewer wants to
   back out without producing feedback for the calling agent.

2. **Send Feedback** — submit `:reject`. Disabled when there are
   zero comments or when a comment form is open (the `unsaved
   form open` marker shows next to it). Exit **1** with the
   formatted comment payload on stderr.

3. **Approve** — submit `:approve` (no comments) or
   `:approve_with_feedback` (any comments). Exit **0**. With no
   comments, stderr prints `The user approved your commit.
   Proceeding.` With comments, stderr prints the formatted feedback
   (so the calling agent sees the approving feedback too).

## Auto-approve fast path

For `--commit-msg` (pre-commit hook) invocations with zero meaningful
staged changes, meerkat exits **0** before binding the server:

- All staged files are linguist-generated → auto-approve with
  `meerkat: all <N> staged file(s) are linguist-generated — auto-approving.`
- All staged files are already approved-by-branch-and-OID + any
  linguist-generated → auto-approve with the matching message.
- No staged files at all (e.g. `git commit --amend` for message only)
  → auto-approve with `meerkat: no staged file changes — auto-approving.`

The UI never opens in these cases.

## Default-deny on crash

Any unhandled exception, throw, or non-decision exit downstream of
`Meerkat.CLI.main/1` exits **2** with a "REJECT — commit aborted"
breadcrumb on stderr. The two-layer `try/rescue/catch` in `cli.ex`
is the safety net: the only path to exit 0 is an explicit Approve
button click or the auto-approve fast path.

In dev mode (`MIX_ENV=dev`), the shepherd loop in `bin/meerkat-beam`
treats non-zero exits as "wait for source change + restart" so the
user's review tab doesn't die when the BEAM crashes mid-iteration.
This applies only to dev; prod (release-installed `meerkat`)
propagates the exit normally.

## Persistence across decisions

A terminal decision deletes the in-progress JSON snapshot at
`<gitdir>/meerkat-precommit/in-progress/<review_id>.json`. The
next invocation of meerkat for the same review_id starts with an
empty state — comments do NOT leak across review cycles.

## Review log

Every terminal decision also writes one JSON record to
`<gitdir>/meerkat-precommit/reviews/<ts>-<branch>-<oid8>.json`
via `Meerkat.ReviewLog.finalize/3`. `decision: in-progress`
indicates the BEAM died before a decision; that file is the
forensic record for any post-mortem.

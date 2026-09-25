# Decision flow

The reviewer's verdict produces an exit code that the git-commit hook
(or calling agent) interprets. An open review normally ends when a
button is clicked; the auto-approve fast path exits before the UI opens,
and an auto-approved timeout can end an unanswered review.

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

## Review timeout

A review's deadline is 90 minutes by default. `MEERKAT_REVIEW_TIMEOUT`
sets it in whole seconds; `0` removes the deadline and countdown.
Unparseable values are ignored, leaving the 90-minute default. The
footer countdown shows `mm:ss left` before the deadline, then
`mm:ss over`.

`MEERKAT_AUTO_APPROVE_ON_TIMEOUT` is off by default. Values `1`,
`true`, or `yes` turn it on, ignoring case and surrounding whitespace.
`0`, `false`, `no`, empty, or unset leave it off. Any other value
prints a one-line warning naming the value on stderr when the review
starts, and leaves auto-approval off.

With auto-approval off, reaching the deadline does nothing: the review
stays open until a button is clicked. With it on, the timeout exits
**0** with `No review within <limit>: commit auto-approved. Nobody read
this diff.` on stderr, followed by any comments saved before the
timeout.

On each 15-second deadline check, an overdue review that is still
waiting refreshes the mtime of this run's deadline directory, if it
exists; it never creates one. Pruning removes other runs' deadline
directories once their mtime is older than the timeout limit plus two
deadline-check intervals. The extra two intervals cover the gap
before an overdue review's first post-deadline check refreshes its
directory. Pruning is disabled when the deadline is disabled.

## Default-deny on crash

Any unhandled exception, throw, or non-decision exit downstream of
`Meerkat.CLI.main/1` exits **2** with a "REJECT — commit aborted"
breadcrumb on stderr. The two-layer `try/rescue/catch` in `cli.ex` is the safety net: the
only paths to exit 0 are an explicit Approve button click, the
auto-approve fast path (no meaningful staged changes, so the UI never
opens), a timeout with `MEERKAT_AUTO_APPROVE_ON_TIMEOUT` enabled, and a
stored `--answers` payload, which runs no review at all.

In dev mode (`MIX_ENV=dev`), the shepherd loop in `bin/meerkat-beam`
treats non-zero exits as "wait for source change + restart" so the
user's review tab doesn't die when the BEAM crashes mid-iteration.
This applies only to dev; prod (release-installed `meerkat`)
propagates the exit normally.

## When the caller exits

Both launchers start the review server detached from the process
that invoked them. That invocation attaches to the server, prints
what it streams, and exits with the code it sends. When the
invocation exits first, by any signal, Ctrl-C included, the server
keeps serving the review and saving its comments.

If the process that ran meerkat is killed instead—for example,
`git commit` is killed by SIGTERM or SIGKILL—its hook can keep
running. Meerkat notices an exited ancestor within about a second
and detaches. A decision clicked while no invocation is attached
stays held for the next invocation.

A decision clicked while no invocation is attached is held. The
next invocation of the same review attaches to the same server and
gets that decision byte for byte, with its exit code. Cancel is held
like any other decision. The same review means the same staged
content and the same commit message. When either has changed, the
old server exits and the invocation starts a new one.

Only one invocation of a review waits on it at a time: a later
invocation takes the review over, and the earlier one prints
`meerkat: a later invocation of this review took it over — aborting.`
and exits 1, aborting its commit. An invocation that collects a
decision already made prints the decision's output only, with no
pause banner and no browser tab.

A server whose invocation exited stays up until a later invocation
of the same review attaches to it. The review deadline runs only
while an invocation is attached, and each one gets the full limit.
A waiting invocation that reattaches opens the browser if no tab is
already connected and `--no-open` was not passed.

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

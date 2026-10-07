# Decision flow

The reviewer's verdict produces an exit code that the git-commit hook
(or calling agent) interprets. An open review normally ends when a
button is clicked; the auto-approve fast path exits before the UI opens,
and an auto-approved timeout can end an unanswered review.

## Buttons

The footer buttons appear left to right as follows. **Post to GitHub**
appears only when the review has an attached PR and is not a staged
(pre-commit hook) review. `--pr` reviews have an attached PR; so do
single-commit and range reviews when the current branch has an open
GitHub PR.

1. **Cancel** — abandon the review. Wipes every in-progress
   comment, submits a `:cancel` decision. The BEAM exits **1** and
   prints `Review cancelled — commit aborted, no feedback to act
   on.` to stderr (the comments were wiped, so there's no feedback
   payload — just the verdict line). Use when the reviewer wants to
   back out without producing feedback for the calling agent.

2. **Post to GitHub** — export the review's comments to the PR as a
   GitHub PENDING review. Disabled while any comment form is open.
   Posting does not end the review: on success, the browser opens the
   pending review's URL in a new tab; on failure, the page shows an
   error banner.

3. **Send Feedback** — submit `:reject`. Disabled when there are
   zero comments or when any comment form is open. The footer shows
   `N unsaved form open:` or `N unsaved forms open:`, with a link for
   each form. Links are labelled `Global`, a file name, an inline
   location such as `src/main.rs L3–5` (or `src/main.rs L3` for one
   line), or `Commit message L1–3`. Inline forms on the old side add
   ` (old)`; edit forms add ` (editing)`. Clicking a link shows its
   file if hidden (clearing a filter that hides it and expanding it
   if collapsed), switches an inline form from rendered markdown
   back to the diff, then scrolls to the form and focuses its text
   box. Exit **1** with the formatted comment payload on stderr.
   Cmd+Shift+Enter on macOS or Ctrl+Shift+Enter elsewhere works from
   anywhere on the review page, does exactly what clicking Send
   Feedback does, and does nothing while the button is disabled. The
   button shows “⇧⌘↩” after its label on macOS and
   “Ctrl+Shift+Enter” elsewhere.

4. **Approve** — labelled **Approve with feedback** when the review
   has any comments, and **Approve** otherwise. Submits `:approve`
   (no comments) or `:approve_with_feedback` (any comments).
   Disabled while any comment form is open. Exit **0**. With no
   comments, stderr prints `The user approved your commit.
   Proceeding.` With comments, stderr prints the formatted feedback
   (so the calling agent sees the approving feedback too).

## Auto-approve fast path

For staged-diff reviews (`meerkat` with no target or
`meerkat --commit-msg <PATH>`) with zero meaningful staged changes,
meerkat exits **0** before binding the server:

- All staged files are linguist-generated → auto-approve with
  `meerkat: all <N> staged file(s) are linguist-generated — auto-approving.`
- All staged files are already approved-by-branch-and-OID + any
  linguist-generated → auto-approve. With no generated files, print
  `meerkat: all <N> staged file(s) already approved — auto-approving.`;
  if any are generated, print
  `meerkat: all <N> staged file(s) already approved (<A>) or linguist-generated (<G>) — auto-approving.`
  During a rebase, lookup uses the branch being rebased, so split or
  regrouped commits whose files were approved before still auto-approve.
- No staged files at all (e.g. `git commit --amend` for message only)
  → auto-approve with `meerkat: no staged file changes — auto-approving.`

The UI never opens in these cases.

A BEAM respawned by the shepherd for the same review skips the fast
path and resumes the live review with its Approved ticks and comments,
even when every staged file is ticked Approved. This covers exit-75
restarts onto a new version or after a code change, and the prod
shepherd's single retry after crash exit 2. When the CLI announces the
review, it writes a `served` marker file in the review's run dir;
a BEAM that starts and finds this marker skips the fast path. The
launcher starts each review's backend in a newly created run dir, so
a new invocation still gets the fast path.

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

In dev mode (`MIX_ENV=dev`), the `bin/meerkat-beam` shepherd
restarts the BEAM only for exit 75, preferring the port the exited
BEAM bound (see [dev-mode.md](dev-mode.md) for when it falls back to
another port); it propagates every other exit, including crash exit
2. After a failed compile or asset build, it waits for a source change
before retrying; if its checkout or `$MEERKAT_PWD` is deleted while
it waits, it exits 2 with a REJECT message. The prod launcher
(`bin/meerkat-shepherd`) retries crash exit 2 once, then exits with
the code.

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

For `git commit -a` and `git commit <path>`, the review keeps its own
copy of git's temporary index, so it keeps showing those changes and
accepting decisions after git removes the original, including after the
review server restarts. If the review cannot keep that copy, for
example because `git commit` was killed before the review started,
meerkat exits 2 and the commit is rejected.

A decision clicked while no invocation is attached is held. The
next invocation of the same review attaches to the same server and
gets that decision byte for byte, with its exit code. Cancel is held
like any other decision. The same review means the same staged
content and the same commit message. When either has changed, the
old server exits and the invocation starts a new one. The
[`GIT_INDEX_FILE` entry in cli.md](cli.md#env-vars) says which index
an invocation's staged content is read from.

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

The in-progress snapshot lives at
`<gitdir>/meerkat-precommit/in-progress/<review_id>.json`.

Right after the decision, before delivery, the CLI calls
`ReviewServer.delete_snapshot/2` once. If a `ReviewServer` is
registered, deletion runs inside that process after any save already
in progress; otherwise, the file is deleted directly. Once
`Decision.current/0` is non-nil, `ReviewServer` still applies and
broadcasts mutations but no longer saves the snapshot, so it stays
deleted.

The decision broadcast switches all connected tabs to the done view,
and tabs mounted later also open on done. The next invocation for the
same `review_id` starts without comments, including a replacement
after only the commit message has changed.

## Review log

Every terminal decision also writes one JSON record to
`<gitdir>/meerkat-precommit/reviews/<ts>-<branch>-<oid8>.json`
via `Meerkat.ReviewLog.finalize/3`. `decision: in-progress`
indicates the BEAM died before a decision; that file is the
forensic record for any post-mortem.

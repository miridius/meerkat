# Decision flow

The reviewer's verdict produces an exit code that the git-commit hook
(or calling agent) interprets. An open review normally ends when a
button is clicked; the auto-approve fast path exits before the UI opens,
an auto-approved timeout can end an unanswered review, and a review
with no comments ends once
[nothing waits on it](#when-nothing-waits-on-the-review).

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
   (so the calling agent sees the approving feedback too). Approve also
   marks every staged file approved for the branch, which feeds the
   auto-approve fast path below. An Approve clicked after another tab
   already decided the review is ignored and marks no file approved.

## Questions block the next review

Every question in Send Feedback, Approve with feedback, or timeout
feedback is saved as a per-worktree obligation before the feedback can
reach the agent. Restored questions receive the same ▶ ACTION count,
answer walkthrough and re-review instructions as fresh questions.

While any question has no matching nonblank answer, **every** next
review in that worktree exits **1** before resolving its target, opening
a browser or auto-approving. The agent sees the refusal, each unanswered
question's location and text, the `meerkat --answers` walkthrough, and
an instruction to re-run the refused command. No page opens for the
reviewer. Reattaching a waiting review also checks this gate; its refusal
ends only the new caller, preserving that review and its comments.
Collecting an already completed review's held feedback still delivers
that feedback. A partial answer set lists only the questions still owed.
`--answers` itself is never blocked.

Once all questions are answered, the next review opens with the existing
Pending answers banner, including for an empty staged diff. Obligations
survive BEAM restarts, reinstalls and new agent sessions, independently
of the in-progress snapshot. Cancel wipes the current round and owes
nothing. See [pending-answers.md](pending-answers.md) for matching,
storage and lifecycle details.

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

The UI never opens in these cases. This fast path is unreachable while
questions are unanswered, or while answers await the reviewer's reading.

A BEAM respawned by the shepherd for the same review skips the fast
path and resumes the live review with its Approved ticks and comments,
even when every staged file is ticked Approved. This covers exit-75
restarts onto a new version or after a code change, and the prod
shepherd's single retry after crash exit 2. When the CLI announces the
review, it writes a `served` marker file in the review's run dir;
a BEAM that starts and finds this marker skips the fast path. The
launcher starts each review's backend in a newly created run dir, so
a new invocation still gets the fast path.

Before each BEAM it starts, the shepherd rewrites the run dir's
`token` and `pid` files if either is missing, so a caller can always
reattach to a review it keeps alive, however long it waits.

A review whose BEAM ended without a decision and was not respawned
(a crash in dev mode, a SIGKILL'd BEAM, a crash after the prod
shepherd's retry) leaves its comments in the review's
[in-progress snapshot](#persistence-across-decisions). A new
invocation of the same review, with the same staged content, skips
the fast path while that snapshot holds any comment, and opens the
review with the comments restored, so a decision delivers them.
A snapshot that cannot be read or parsed also skips the fast path;
the review then starts without comments and prints a warning naming
the snapshot.

## Review timeout

A review's deadline is 90 minutes by default. `MEERKAT_REVIEW_TIMEOUT`
sets it in whole seconds; `0` removes the deadline and countdown.
Unparseable values are ignored, leaving the 90-minute default. The
footer countdown shows `h:mm:ss left` before the deadline, then
`h:mm:ss over`, in that shape at every length: `0:04:17`, `1:08:17`,
and past a day the hours keep counting (`68:28:17`).

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

Once `Meerkat.CLI.main/1` has started, a SIGTERM sent directly to
the review BEAM also defaults to REJECT. The BEAM prints
"meerkat: received SIGTERM — stopping the review, defaulting to REJECT (commit aborted)."
to stderr, flushes the log file, and halts with exit **143** at
once, without waiting for HTTP connections to close. Neither
`bin/meerkat-beam` nor `bin/meerkat-shepherd` restarts or retries
it; both pass 143 to the caller.

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
keeps serving a review that has comments or an open comment form,
and saving its comments; a review with neither
[ends](#when-nothing-waits-on-the-review).

An invocation stopped by SIGTERM, SIGINT or SIGHUP before it has the
decision tells whoever ran it so, printing
`meerkat: stopped waiting (SIGTERM) before the review completed. The review stays open at <url> if it has comments or an open comment form; run the same command again to wait for its outcome.`
(naming the signal it got, and leaving out ` at <url>` while the
server is still starting), then dies of that signal. The pause
banner covers an invocation killed without a chance to print, as by
SIGKILL: it says an output that ends after the banner with no outcome
line means the review stays open if it has comments or an open
comment form.

If the process that ran meerkat is killed instead—for example,
`git commit` is killed by SIGTERM or SIGKILL—its hook can keep
running. Meerkat notices an exited ancestor within about a second,
prints the same line with `the process that ran meerkat exited` in
place of `stopped waiting (SIGTERM)`, and exits 1. Where `ps` is
denied, as in Claude Code's sandbox, it cannot tell and keeps
waiting. A decision clicked while no invocation is attached stays
held for the next invocation.

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

An invocation exits with its own server's code even when that server
is killed: 143 when it is SIGTERMed, or 2 with a REJECT message if it
is killed before recording a code. This holds even if a rerun of the
same review has already started a new server; the rerun waits on
that new server. An invocation that returns more than a minute after
its server finished (for example, after the laptop slept), when the
same review was rerun meanwhile, finds its run gone and exits 2 with
a REJECT message.

Only one invocation of a review waits on it at a time: a later
invocation takes the review over, and the earlier one prints
`meerkat: a later invocation of this review took it over — aborting.`
and exits 1, aborting its commit. An invocation that collects a
decision already made prints the decision's output only, with no
pause banner and no browser tab.

The review deadline runs only while an invocation is attached, and
each one gets the full limit. A waiting invocation that reattaches
opens the browser if no tab is already connected and `--no-open` was
not passed.

## When nothing waits on the review

A review left with no invocation waiting on it and no decision is
judged once, when the server learns the invocation is gone:

- An attached invocation is gone once its attach stream drops, about
  1.5 seconds after it dies.
- An invocation that died before it attached, for example while the
  dev launcher compiled or the BEAM booted, is gone once the run dir's
  `caller` file names a process that `ps` shows is not a running
  meerkat. The server checks once a second until an invocation
  attaches. Where `ps` is denied, as in Claude Code's sandbox, it
  cannot tell and keeps waiting.

If the review then has no saved comment and no comment form open, it
ends:

- Every connected tab switches to a done view headed **Review
  ended**, and tries to close itself. Browsers allow that only for a
  tab whose history holds one page, such as the tab meerkat opened
  before any in-page link was followed; any other tab keeps showing
  the notice. A tab opened later also shows it, until the BEAM exits.
- The review log records `decision: ended`.
- The BEAM exits **1**, printing
  `meerkat: no invocation was waiting on this review and it had no comments, so it ended.`
  to its log, and frees its port. Its run dir stays until the next
  invocation with the same arguments in the same directory removes
  it, as for any finished run whose caller is gone.
- The in-progress snapshot is kept, so a rerun of the same review
  restores its Approved ticks and filters. A rerun is a new
  invocation, so when every staged file was ticked Approved it takes
  the [auto-approve fast path](#auto-approve-fast-path).

A later invocation that reaches the ending review is turned away and
starts a new one. A button clicked after the review ended does
nothing but show the notice.

Otherwise the server stays up until a later invocation of the same
review attaches to it. Deleting the review's comments afterwards does
not end it; only another invocation that attaches and then goes away
is judged again. A decision clicked before the invocation went away
is held for the next one, as above.

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
after only the commit message has changed. Questions delivered to the
agent remain owed in `pending-questions.json`, outside that snapshot;
a fresh review cannot start until they have answers.

## Review log

Every terminal decision also writes one JSON record to
`<gitdir>/meerkat-precommit/reviews/<ts>-<branch>-<oid8>.json`
via `Meerkat.ReviewLog.finalize/3`, as does a review that
[ended with nothing waiting on it](#when-nothing-waits-on-the-review),
with `decision: ended`. `decision: in-progress` indicates the BEAM
died before a decision; that file is the forensic record for any
post-mortem.

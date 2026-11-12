# Pending answers

The agent's answers to a prior round's comments, shown on an answers
page as soon as the agent gives them, and pinned in a banner at the
top of the next review (below the page header, above the
commit-message section) until the reviewer marks them read.

## Why

Some review cycles end with the reviewer asking the agent a
question (a `question`-type comment) rather than accepting /
rejecting a change. The feedback meerkat prints tells the agent to
answer and hand the answers back with `meerkat --answers`, which
stores them in `<gitdir>/meerkat-precommit/pending-answers.json` and
opens them on the [answers page](#answers-page), so the reviewer reads
them without the agent rerunning the commit. Answers the reviewer has
not marked read are pinned in the next review, so the reviewer sees
them next to the diff they asked about. Every question
in delivered feedback must have an answer before that review starts.
This blocks the agent, not the reviewer.

A comment of any other type can hold a question too, such as an Issue
that asks "why not reuse X?". Every comment therefore has an optional
answer slot: the agent may answer any comment, and must answer only
the question-type ones.

## How answers arrive

The agent runs, from the repo:

```sh
meerkat --answers <<'JSON'
{
  "answers": [
    {
      "location": "src/foo.clj:123 (new)",
      "question": "Did you mean to also touch the X handler?",
      "answer": "Yes — landing in a follow-up PR."
    }
  ]
}
JSON
```

`PendingAnswers.save/2` validates the JSON (an object with a
non-empty `answers` list whose entries each have string `location`,
`question` and `answer`), stamps `version` and `createdAt`, and
writes the file atomically. Exit `0` on success; exit `1` with the
reason on stderr, and no file written, on bad input. A failure the
agent cannot fix by sending better JSON exits `64`, `74` or `2`
instead, so it knows to stop retrying: see
[cli.md](cli.md#exit-codes). A repeat run replaces the earlier
answers, so the agent must send the complete set, including answers
already submitted. The agent never writes the file itself.

Feedback with a question always includes the ▶ ACTION count and the
`meerkat --answers` walkthrough, including after comments were
restored from an in-progress snapshot. Feedback without a question
still includes the walkthrough, marked optional. The walkthrough tells
the agent to carry on with its work once the answers are stored: it
need not rerun the commit or `meerkat` for the reviewer to see them.
The walkthrough lists every comment with its actual location and
verbatim text, in the `question` field whatever the comment's type:
copy these unchanged, replace each question's answer placeholder with
a nonblank answer, and either answer each other comment or drop its
entry. An answer to a non-question comment shows in the banner like
any other. Locations are
`path:line[-line] (old|new)` for inline questions, `file: path` for file
questions, `global`, or `commit-message:line[-line]`.

## Answers page

Once `meerkat --answers` has stored the answers, it starts a page
server for them, as the launchers start a review's, opens the page in
the browser unless `--no-open` is passed, prints its URL on stderr
with an instruction to give the user that URL, and exits `0` at once.
The agent does not wait for the reviewer.

The page lists each answered comment: its location, the comment's
text and the agent's answer, rendered as Markdown. It is read-only
apart from one **Mark read** button. Mark read deletes the stored
answers and the owed questions they answered, so the next review pins
no banner and may auto-approve again; the page then shows that the
answers were marked read.

The page server exits on Mark read, when the next review in the same
worktree starts, or at the review deadline (`MEERKAT_REVIEW_TIMEOUT`,
90 minutes by default), whichever comes first. A repeat
`meerkat --answers` shows its new set on the page. Answers not marked
read stay stored and are pinned in the next review.

## Unanswered-question gate

Before resolving any review target, auto-approving, binding the server,
or opening a browser, meerkat checks the worktree's owed questions.
Send Feedback, Approve with feedback, and timeout feedback persist
these obligations before their feedback can reach the agent. Cancel
wipes the round's comments and owes no questions.

If any question lacks an answer with the same location and verbatim
question text and a nonblank answer, the next review exits **1** without
opening a page. Stderr says the review was refused because questions
are unanswered, lists only the still-unanswered questions with their
locations and text, prints the same answer walkthrough, and tells the
agent to re-run the refused command. This applies to every review target,
including `git commit`, bare meerkat with no staged changes, ref/range,
and PR reviews. Reattaching an existing waiting review is also gated;
the refusal ends only that caller and keeps the review's backend and
in-progress comments. Collecting a completed review's held feedback is
not a new review and still delivers the feedback. `meerkat --answers`
is never blocked by this gate.

A complete answer set passes the gate. Until the reviewer marks it read,
it forces a live review, even over an empty staged diff, with the answers
pinned in the banner.
A partial set cannot open a review. Questions remain owed across BEAM
restarts, reinstalls, branch changes and new agent sessions, within the
same worktree. Another worktree has independent obligations.

## Schema

The stored file:

```json
{
  "version": 1,
  "createdAt": "2026-04-25T12:34:56Z",
  "answers": [
    {
      "location": "src/foo.clj:123 (new)",
      "question": "Did you mean to also touch the X handler?",
      "answer": "Yes — landing in a follow-up PR."
    }
  ]
}
```

Best-effort: a missing file, malformed JSON, or wrong `version` →
`PendingAnswers.load/1` returns `nil` and no banner renders. A real
fault leaves a `:stderr` warning but never takes the review down.

Owed questions have their own version-1 file at
`<gitdir>/meerkat-precommit/pending-questions.json`, containing a
`questions` list of `location`/`question` pairs. Unlike the best-effort
answer banner, unreadable or malformed obligations fail closed and remain
on disk: a new backend exits **2**, while an invocation reattaching an
existing waiting backend exits **1** without stopping it. A write failure
prevents feedback from
being delivered as a successful terminal decision.

## Lifecycle

- Owed questions are recorded from the accepted round's feedback,
  independently of its in-progress snapshot. Passing the gate alone
  does not delete obligations or answers. A later terminal round
  replaces the obligations with that round's questions; Approve without
  feedback or Cancel clears them. A late decision from another tab
  cannot overwrite the accepted decision's obligations.
- Answers are written by `meerkat --answers`, which opens the answers
  page.
- Mark read on the answers page deletes the answers and drops the
  owed questions they answer.
- Read once at `mount/3` via `PendingAnswers.load(repo_path)`.
- Cleared on ANY terminal decision (Approve / Reject / Cancel / timeout)
  via `clear_pending_answers/0` or `Timeout.decision/2` →
  `PendingAnswers.clear(repo_path)` → `File.rm` on the path. Timeout
  also consumes the displayed answer set, so an old answer cannot
  satisfy a newly asked question with identical text.
- Auto-approve fast path also clears it (
  `finalise_auto_approve/1`), so the next live review doesn't
  pin stale entries.

## Render

```
<section class="pending-answers">
  <h2>Pending answers ({N})</h2>
  <ul>
    <li class="pending-answer">
      <div class="location">{location}</div>
      <div class="question">Q: {question}</div>
      <div class="answer">A: {answer}</div>
    </li>
  </ul>
</section>
```

The banner has no interactivity beyond reading — the answers are static carry-
overs, not action items. The reviewer reads them, files them in
memory, decides whether the current diff addresses them, then
hits Approve / Send Feedback / Cancel. The clear-on-decision
behaviour means a fresh review never inherits the prior round's
entries unless the prior round was abandoned mid-decision (BEAM
crash before terminal exit).

# Pending answers banner

A pinned banner at the top of the review (below the page header,
above the commit-message section) that surfaces unresolved
questions left by a prior round.

## Why

Some review cycles end with the reviewer asking the agent a
question (a `question`-type comment) rather than accepting /
rejecting a change. The feedback meerkat prints tells the agent to
answer and hand the answers back with `meerkat --answers`, which
stores them in `<gitdir>/meerkat-precommit/pending-answers.json`.
The next meerkat invocation loads them and shows them pinned, so
the reviewer sees the answers next to the diff they asked about.

## How answers arrive

The agent runs, from the repo:

```sh
meerkat --answers <<'JSON'
{
  "answers": [
    {
      "location": "src/foo.clj:123",
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
answers. The agent never writes the file itself.

## Schema

The stored file:

```json
{
  "version": 1,
  "createdAt": "2026-04-25T12:34:56Z",
  "answers": [
    {
      "location": "src/foo.clj:123",
      "question": "Did you mean to also touch the X handler?",
      "answer": "Yes — landing in a follow-up PR."
    }
  ]
}
```

Best-effort: a missing file, malformed JSON, or wrong `version` →
`PendingAnswers.load/1` returns `nil` and no banner renders. A real
fault leaves a `:stderr` warning but never takes the review down.

## Lifecycle

- Written by `meerkat --answers` before the agent's next `git commit`
  or bare `meerkat`.
- Read once at `mount/3` via `PendingAnswers.load(repo_path)`.
- Cleared on ANY terminal decision (Approve / Reject / Cancel)
  via `clear_pending_answers/0` → `PendingAnswers.clear(repo_path)`
  → `File.rm` on the path.
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

No interactivity beyond reading — the answers are static carry-
overs, not action items. The reviewer reads them, files them in
memory, decides whether the current diff addresses them, then
hits Approve / Send Feedback / Cancel. The clear-on-decision
behaviour means a fresh review never inherits the prior round's
entries unless the prior round was abandoned mid-decision (BEAM
crash before terminal exit).

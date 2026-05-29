# Pending answers banner

A pinned banner at the top of the review (below the page header,
above the commit-message section) that surfaces unresolved
questions left by a prior round.

## Why

Some review cycles end with the agent asking the human for
clarification (rather than accepting / rejecting a change). Those
questions live in
`<gitdir>/meerkat-precommit/pending-answers.json`. The next
meerkat invocation loads them and shows them pinned, so the
reviewer doesn't lose track of what they still owe the agent.

## Schema

```json
{
  "schema_version": 1,
  "answers": [
    {
      "location": "src/foo.clj:123",
      "question": "Did you mean to also touch the X handler?",
      "answer": "Yes — landing in a follow-up PR."
    }
  ]
}
```

Best-effort: a missing file, malformed JSON, or wrong
`schema_version` → `PendingAnswers.load/1` returns `nil` and no
banner renders. A real fault leaves a `:stderr` warning but never
takes the review down.

## Lifecycle

- Written by external tooling (the agent calling meerkat) before
  invoking `meerkat`.
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

# Non-inline comment surfaces

Three comment surfaces other than inline:

1. **Global** — page-level, not tied to any file. Use for review
   summaries, cross-cutting feedback.
2. **File** — attached to a file as a whole. Use when feedback
   spans the file but doesn't anchor to a specific line range.
3. **Commit-message** — anchored to one block of the commit
   message. Use when the message itself is wrong / unclear.

Inline comments (line-anchored, in `inline-comments.md`) are the
fourth surface and the most common in practice.

## Shared affordances

All three non-inline surfaces share the same `CommentForm.svelte`
+ `Meerkat.Comment` shape + edit/remove/learn-toggle mechanics
that inline comments use:

- Five finding-type chips: Issue / Suggestion / Question /
  Follow-up / Revert.
- Body rendered through `Meerkat.Markdown.to_safe_html/1` —
  fenced code blocks, headings, bullets, inline code all work.
- Cmd/Ctrl+Enter submits, Escape cancels.
- localStorage draft persistence on per-surface `draftKey`.
- Inline `learn` checkbox on rendered comments; toggleable in
  place via `comment.toggle_learn` push event.
- Edit reopens form prefilled; Remove drops the comment.
- `learn_from_this` defaults OFF.

## Global comments

Lives under `state.global_comments`. Rendered in a
`<section class="global-comments">` after the page header.

Empty state: a single `+ Add global comment` button.
Populated state: a list of `.note.note-{finding_type}` rows
followed by `+ Add another`.

`open_form: %{surface: :global, anchor: %{}}` opens the form;
submit pushes via `comment.submit` with no anchor payload.

## File comments

Lives under `state.file_comments` keyed implicitly by
`file_index`. Rendered inside each `.file-section`, BELOW the
diff body, in a `<ul class="file-comments">`. The
`+ Add file comment` button sits below that list.

`open_form: %{surface: :file, anchor: %{file_index: N}}` opens
the form. The form is rendered AT THE BOTTOM of the file section
(NOT injected into the diff body — file comments don't anchor at
a specific line). Submit pushes via `comment.submit` with
`file_index` in the payload.

Per-file language is wired through to the form's `language` prop
so Suggestion mode's CodeMirror picks the right syntax pack.

## Commit-message comments

Lives under `state.commit_message_comments`. Anchored to
`{start_line, end_line}` (no side, no file_index). Rendered in
`<ul class="commit-msg-comments">` below the gutter (see
`commit-message.md`).

`open_form: %{surface: :commit_msg, anchor: %{start_line, end_line}}`
opens the form. Submit pushes via `comment.submit` with
`start_line` / `end_line` in the payload.

## Why the form lives elsewhere for each surface

The form's location is the meaningful affordance:

- **Global** form lives in the global section after the page
  header — review-summary-style feedback lands at the top.
- **File** form lives at the bottom of the file section — "anything
  to say about this file before moving on?".
- **Commit-message** form lives below the gutter — co-located
  with the message it's commenting on.
- **Inline** form is DOM-injected at the anchor row — co-located
  with the line of code.

A single CommentForm component handles all four; the differences
are entirely in where it's mounted and what `extraPayload` it
carries.

## GitHub PENDING review export

The `Post to GitHub` button in the decision footer (renders only
when `state.pr` is set and the review is not in precommit mode)
flattens all four surfaces into a single GitHub PENDING review:

- Inline comments → per-line review comments on the new side.
- File / global / commit-msg comments → concatenated into the
  review body via `Meerkat.Feedback.format/2`.

GitHub doesn't model file-level or commit-message-level review
comments separately, so flattening into the body is the cleanest
mapping. The reviewer's intent (a file-level note vs a global
note) is preserved in the formatted prose, not in the GitHub data
model.

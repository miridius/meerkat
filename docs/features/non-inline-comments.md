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
- Several forms can be open at once, across surfaces and files;
  opening one never closes another. Submit and cancel send that
  form's `form_key`.
- Each form's `draftKey` stores a JSON draft in localStorage of the
  prose, suggestion code, finding type and learn flag values that
  differ from how the form opened, for add and edit forms. It is
  written on every change, removed when the form returns to its
  opening values, and cleared on submit or cancel. Plain-prose drafts
  saved before this change still load; a `storage` listener mirrors
  changes to other tabs already showing the form, and opening or
  reloading a form restores the draft. Multiple forms on the same
  surface can be open.
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

`ReviewState.open_forms` holds each form's surface and anchor.
A global form has `surface: :global` and `anchor: %{}`. Its submit
pushes `comment.submit` with that form's `form_key`; the server uses
the named form, not an anchor payload.

## File comments

Lives under `state.file_comments` keyed implicitly by
`file_index`. Rendered inside each `.file-section`, BELOW the
diff body, in a `<ul class="file-comments">`. The
`+ Add file comment` button sits below that list.

`open_forms` can contain forms with `surface: :file` and
`anchor: %{file_index: N}`. Each matching form is rendered AT THE
BOTTOM of the file section
(NOT injected into the diff body — file comments don't anchor at
a specific line). Submit pushes via `comment.submit` with the form's
`form_key`; the server ignores any payload `file_index` and takes
`file_index` from that form's anchor.

Per-file language is wired through to the form's `language` prop
so Suggestion mode's CodeMirror picks the right syntax pack.

## Commit-message comments

Lives under `state.commit_message_comments`. Anchored to
`{start_line, end_line}` (no side, no file_index). Rendered in
`<ul class="commit-msg-comments">` below the gutter (see
`commit-message.md`).

`open_forms` can contain forms with `surface: :commit_msg` and
an anchor of `%{start_line: N, end_line: M}`. Each form is labelled
`L{N}–{M}`. Submit sends the form's `form_key`; the server uses that
form's anchor for the comment range.

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

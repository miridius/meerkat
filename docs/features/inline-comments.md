# Inline comments

Comments anchored to a specific line range on a specific side
(old/new) of a specific file's diff. The dominant comment surface
in practice — the spatial association with code is what makes the
review readable.

## Opening the form

The reviewer drags on the **line-number gutter** of any diff row.
The drag captures pointerdown on the start row and pointerup on
the end row. Selection is restricted to the line-num cell so the
code content itself stays selectable for copy/paste.

- Single click on a line-num → form opens for that single line.
- Drag across multiple lines → form opens for the inclusive range.
- Drag across both sides (old + new) is rejected; the side of the
  pointerdown wins.

The form is injected as `<tr class="meerkat-form-row">` directly
after the row anchoring `end_line`. Its only child is a
full-colspan `<td>` containing the CommentForm component. Only
one inline form is open at a time (across all files); opening a
new one moves the form rather than stacking it.

## Form contents

The form has:

- A Markdown textarea (or, in Suggestion mode, a prose textarea
  plus a CodeMirror code editor).
- Five finding-type chips: Issue, Suggestion, Question, Follow-up,
  Revert. Clicking switches the active type.
- A "Please learn from this" checkbox. **Off** by default.
- Submit + Cancel buttons.

Keyboard shortcuts inside the form:

- **Cmd/Ctrl+Enter** → submit (same as clicking the button).
- **Escape** → cancel (same as clicking Cancel).

The textarea persists its content to `localStorage` under
`meerkat:draft:<review_id>:inline:<file_index>:<side>:<start_line>-<end_line>`
(plus `:edit:<comment_id>` when editing an existing comment) on
every keystroke and clears on submit/cancel. Re-opening the same
anchor restores the draft.

## Suggestion mode

When `finding_type === "suggestion"`:

- The prose textarea shrinks to 2 rows and a CodeMirror editor
  appears below it.
- The CodeMirror editor is seeded with the file content covered
  by the anchor's `(start_line, end_line, side)` — the user
  edits *toward* the proposed change rather than starting blank.
- The editor's syntax-highlighting language is the file's
  detected language (Python → python, TS → typescript, etc., via
  `Meerkat.Git.language_for/1`).
- On submit, the body is composed as
  `<prose>\n\n\`\`\`<lang>\n<code>\n\`\`\``. The fence carries the
  same language tag so GitHub (or any markdown renderer) treats it
  as a suggested change.

## Rendered comment

After submit, the form row disappears and a
`<tr class="meerkat-comment-row">` appears in its place, hosting
an `<InlineComment>` per comment at that anchor. Multiple comments
sharing one anchor stack inside the same row's list.

Each rendered comment shows:

- Finding-type badge (colour-coded by type).
- Line anchor label: `L<N>` or `L<A>–<B>` plus ` (old)`/` (new)`.
- Learn checkbox (toggleable in place — flips
  `learn_from_this` via a `comment.toggle_learn` push event
  without re-opening the form).
- **Edit** button → reopens the form at the same anchor, prefilled
  with the comment's body and finding-type. Submitting an edited
  form removes the old comment and adds a new one.
- **Remove** button → drops the comment from the file's comment
  list; the row removes itself when it has no remaining children.
- Body, rendered through `Meerkat.Markdown.to_safe_html/1` (the
  same server-side renderer the file/global/commit-msg comments
  use). Suggestion fenced blocks become syntax-highlighted
  `<pre><code>` blocks.

## Visual line marker

Every diff row covered by an inline comment range gets the
`has-inline-comment` class, which shows:

- A 3px blue bar on the left edge of the line-num cell.
- A faint blue tint on the row background.

The marker is reactive: removing the comment removes the marker;
adding a comment immediately adds it.

## Persistence

The inline-form state (which surface, which anchor, edit_id,
prefilled body for edit mode) is persisted to ReviewState's
`open_form` field. On BEAM restart (DevWatcher hot reload, crash,
tab close/reopen), the form reopens at the same anchor — the
localStorage draft restores the body content separately.

This is the contract the user relies on during dev iteration: a
hot reload **never** loses an in-progress comment.

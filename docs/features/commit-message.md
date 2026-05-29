# Commit-message gutter

When meerkat is invoked with `--commit-msg <PATH>` (the pre-commit
hook context), the commit message file is read once at startup
and rendered as a clickable gutter above the diff body.

## Source-of-truth

`Meerkat.ReviewState.from_target/2` reads the file via
`read_commit_msg/1`. `git commit` comment lines (lines starting
with `#`) are stripped. The remaining content is the commit
message.

The file is **read once at mount**. Subsequent edits to the file
on disk do NOT re-propagate to a running meerkat — the user has
to restart meerkat (kill the BEAM, re-fire the commit hook). The
deterministic-port shepherd makes that cheap (same URL).

Without `--commit-msg`, this section is omitted entirely.

## Block detection

The message is split into top-level "blocks" — the unit the
gutter button is anchored to:

- Paragraphs (separated by blank lines) are blocks.
- A paragraph that's entirely list items (`- `, `* `, or
  numbered) splits into per-item blocks. Each bullet gets its own
  gutter button so the reviewer can comment on a specific point
  without dragging across the whole paragraph.
- Lines are 1-indexed; each block carries `{start_line, end_line,
  text}`.

The detection lives in `Meerkat.ReviewState.blocks/1` —
self-contained, no git dependency.

## Rendered shape

```
<section class="commit-message-section">
  <ol class="commit-msg-gutter">
    <li>
      <button class="gutter-line-num"
              phx-click="comment_form.show_commit_msg"
              phx-value-start_line="N"
              phx-value-end_line="M">N</button>
      <div class="gutter-text markdown">{markdown-rendered text}</div>
    </li>
    ...
  </ol>
  <ul class="commit-msg-comments">
    <li class="note commit-msg-note">...</li>
  </ul>
  <!-- inline form, rendered when open_form.surface == :commit_msg -->
</section>
```

The text body renders through `Meerkat.Markdown.to_safe_html/1` —
the same pipeline used for comment bodies. Bullet lists,
headings, inline code, and links all work in the gutter just like
in a rendered comment.

## Comments

Comments attached to a commit-message block live on
`state.commit_message_comments` and rendered under the gutter.
Same edit/remove/learn-toggle affordances as other comment
surfaces. Form's anchor carries `{start_line, end_line}` (no
side, no file_index).

Drag-select across multiple gutter buttons is NOT supported —
the gutter uses click, not pointer-drag. To comment on a multi-
block range, the user would have to comment per block. This is
intentional: drag-select on the gutter would conflict with the
diff body's pointer handlers and the per-block comments tend to
read better than range-spanning ones anyway.

## When the commit message is wrong

The displayed message is whatever `read_commit_msg/1` saw at
startup. If the rendered message looks wrong for the staged diff,
likely causes:

1. The file was reused from a prior aborted commit and the user
   didn't realise (git's default `git commit` behaviour pre-fills
   COMMIT_EDITMSG with the last buffer).
2. Two concurrent processes wrote to the same tempfile and one
   clobbered the other.
3. The file changed after meerkat started (meerkat doesn't
   re-read).

Meerkat itself never writes to the commit-msg path — only reads.
A wrong message is a git-side / tooling-side issue, not a meerkat
bug.

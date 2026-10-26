# Approved files collapse

When the reviewer ticks the `Approved` checkbox on a file, the
diff body collapses behind the file header. The header stays
visible (status badge, file name, rename-from chip, line counts,
Approved checkbox) so the file remains discoverable in the list,
but the diff content + inline comments + file form get hidden.

## Toggle override

Clicking the file header (the row containing the caret + status
badge + file name) flips that file between collapsed and
expanded. Approved files start collapsed; clicking expands them
again, through a per-file `expanded_approved` override.
Un-approving and re-approving clears the override (the file
collapses again).

Unapproved files start expanded; clicking collapses them, through
a per-file `collapsed_unapproved` override, and clicking again
expands them. Approving such a file leaves it collapsed, as any
approved file starts. Un-approving it brings it back collapsed,
even if it was expanded while approved: the `collapsed_unapproved`
override survives approval.

The caret rotates `-90°` to point right when collapsed; back to
`▾` (pointing down) when expanded. Pure CSS transition (120ms
ease), no JS.

## Why collapse on approve

A reviewer who has approved a file is done with it. Keeping the
diff body visible:

- consumes vertical space that pushes unreviewed files further
  down,
- invites accidental scroll-past on subsequent re-reviews,
- visually competes with the files still needing attention.

Collapsing reclaims the space and gives the reviewer a clearer
"what's left" picture. The override exists for the case where the
reviewer wants to revisit (re-read context, copy a snippet) after
approving.

## State scope

`expanded_approved` and `collapsed_unapproved` are in-LV
ephemeral state, NOT persisted to `ReviewState`. Reasons:

- The overrides are intentionally ephemeral: a DevWatcher
  hot reload clears them and the user re-expands files they want to
  revisit. The trade-off is one click per file vs persisting
  per-session UI state past a BEAM restart — comment-form state
  IS persisted because losing typed content costs more than
  losing an affordance state.
- Multi-tab convergence: another tab approving the same file
  shouldn't affect this tab's expansion state. Local-only assign
  keeps the model clean.

If a future iteration shows users repeatedly hate the
re-expansion cost across hot reloads, the fields can graduate to
persisted assigns at any time — the helper `file_section_collapsed?/4`
is the single read path.

## DOM markers

- `<article class="file-section approved collapsed">` — the
  collapsed state.
- `<article class="file-section approved">` — approved but
  user-expanded.
- `<article class="file-section collapsed">` — unapproved but
  user-collapsed.
- The `DiffViewer` Svelte component renders only when the section
  is NOT collapsed — the `:if={not file_section_collapsed?/4}` on
  the `<.svelte name="DiffViewer" .../>` controls it. There's no
  DOM cost to a collapsed file beyond the header.

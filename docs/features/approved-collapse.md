# Approved files collapse

When the reviewer ticks the `Approved` checkbox on a file, the
diff body collapses behind the file header. The header stays
visible (status badge, file name, rename-from chip, Approved
checkbox) so the file remains discoverable in the list, but the
diff content + inline comments + file form get hidden.

## Toggle override

Clicking the file header (the row containing the caret + status
badge + file name) toggles a per-file `expanded_approved`
override. Unapproved files are always expanded — toggling does
nothing. Approved files start collapsed; clicking expands them
again. Un-approving and re-approving clears the override (the
file collapses again).

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

`expanded_approved` lives in `ReviewState.view` and is shared by
every tab of the review, but is not persisted. A DevWatcher hot reload
or other BEAM restart clears it.

The trade-off is one click per file to re-expand versus persisting UI
state past a BEAM restart. Comment-form state IS persisted because
losing typed content costs more than losing an affordance state.

If a future iteration shows users repeatedly hate the re-expansion
cost across hot reloads, the field can graduate to a persisted field
at any time — the helper `file_section_collapsed?/4` is the single
read path.

## DOM markers

- `<article class="file-section approved collapsed">` — the
  collapsed state.
- `<article class="file-section approved">` — approved but
  user-expanded.
- The `DiffViewer` Svelte component renders only when the section
  is NOT collapsed — the `:if={not file_section_collapsed?/4}` on
  the `<.svelte name="DiffViewer" .../>` controls it. There's no
  DOM cost to a collapsed file beyond the header.

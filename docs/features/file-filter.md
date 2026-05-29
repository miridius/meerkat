# File filter sidebar

A collapsible left-side panel that lists every file in the diff
with affordances to narrow / hide / focus the main file list.

## Toggle

Hidden by default. The toolbar's `☰ Files` button toggles it via
`toolbar.toggle_files_panel`. State lives on the LV's
`files_panel_open` socket assign (ephemeral, NOT persisted).

When open, the `.review-body` grid becomes `260px 1fr`; when
closed, `1fr` (diff body uses the full viewport). The breakpoint
at `max-width: 900px` collapses to a single column even when the
panel is open.

## Sidebar contents

Top to bottom:

1. **Title row**: `Files (visible_count of total_count)` plus
   `Hide matched` / `Show matched` (one toggle whose label depends
   on whether every currently-filtered file is visible) and
   `Show all` (visible when `only_file_index != nil` OR any
   `file_overrides` entry is set; clears overrides).
2. **Filter input**: a debounced (50ms) `phx-change="filter.set_input"`
   text box. Filters the sidebar list AND the main file list by
   case-insensitive substring on the file's base name.
3. **Generated-file chip**: `generated ✓` / `generated ×` —
   click to toggle `show_generated`. Only renders when at least
   one file in the diff has `is_generated = true` (from
   `linguist-generated` git attribute batched lookup). Off by
   default — linguist-generated files (lockfiles, vendored bundles)
   hide unless the user opts in.
4. **Hidden-extensions chips**: each hidden extension renders as
   a chip; click to unhide.
5. **File entries**: one row per file matching the filter.

## Per-entry affordances

Each row in the file-entries list shows:

- An `Approved` checkbox (mirrors the per-file checkbox in the
  main file list — share one assign).
- The file's status badge (A/M/D/R).
- The file's base name (truncated with ellipsis at the row
  boundary).
- A hover-revealed `only` button (shows ONLY this file in the
  main list via `filter.show_only`).
- A hover-revealed `hide *.<ext>` button (hides all files of this
  extension via `filter.toggle_extension`). Only renders when the
  file has an extension.

## State

- `state.hidden_extensions` (MapSet, persisted) — extensions
  filtered out of the main list.
- `state.show_generated` (boolean, persisted) — flips
  generated-file visibility.
- `state.file_overrides` (`%{file_name => :show | :hide}`,
  persisted) — explicit per-file checkbox state. Takes precedence
  over the extension / generated / filter rules.
- `filter_input` (string, in-LV ephemeral) — substring filter.
- `only_file_index` (int | nil, in-LV ephemeral) — "show only
  this file" override.
- `state.approved_file_names` (MapSet, persisted) — driven by
  the per-row Approved checkbox.

Hidden / show_generated / file_overrides / approved-files survive
a BEAM restart. `filter_input` and `only_file_index` don't —
they're tab-local narrowing affordances.

## Composition

The visible-files set is `visible_indices/3` walking each file:

1. If `file_overrides[file_name]` is set, use it directly
   (`:show` → visible, `:hide` → hidden). This wins over every
   other rule so the per-row checkbox is always authoritative.
2. Otherwise, drop generated files unless `show_generated`.
3. Otherwise, drop files whose extension is in `hidden_extensions`.
4. If `only_file_index` is set, drop everything else.
5. If `filter_input` is non-empty, drop files whose base name
   doesn't contain the substring (case-insensitive).

Order matters: `file_overrides` is first because user-explicit
choice should beat any heuristic. `only_file_index` short-circuits
before the substring filter so "only this file" wins over a stale
filter string.

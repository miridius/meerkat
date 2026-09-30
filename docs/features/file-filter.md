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

- A file-visibility checkbox. Its tooltip is `Show / hide <file>
  in the diff list`; it is checked when the file is visible.
  Unticking a visible file records a `:hide` override in
  `state.file_overrides`; ticking a hidden file records a `:show`
  override. If another file is shown alone, ticking a hidden file
  also clears the “only” filter so the main list returns to all
  files still allowed by hidden-extension and generated-file
  filters, per-file overrides, and the filter text. This is not an
  approval checkbox; approving a file is done only with the
  per-file checkbox in the main file list.
- The file's status, shown as a coloured dot whose tooltip names
  the status.
- The file's name is a link showing its directory followed by its
  base name, truncated with an ellipsis at the row boundary.
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
  persisted) — explicit per-file override. `:hide` always hides;
  `:show` bypasses only the persisted generated-file and
  hidden-extension filters, not `only_file_index` or `filter_input`.
- `filter_input` (string, in-LV ephemeral) — substring filter.
- `only_file_index` (int | nil, in-LV ephemeral) — "show only
  this file" override.
- `state.approved_file_names` (MapSet, persisted) — driven by
  the per-file Approved checkbox in the main file list, not by
  the sidebar row.

Hidden / show_generated / file_overrides / approved-files survive
a BEAM restart. `filter_input` and `only_file_index` don't —
they're tab-local narrowing affordances.

## Composition

`visible_indices/3` includes a file only if it passes the applicable rules:

1. A `:hide` override always hides the file.
2. The ephemeral filters apply to every file, including files with a
   `:show` override. If `only_file_index` is set, every other file is
   hidden. If `filter_input` is non-empty, the base name must contain
   it (case-insensitive). These conditions are ANDed, so a file selected
   by "show only" is still hidden if it does not match the filter string.
   `filter.show_only` does not clear `filter_input`.
3. A `:show` override bypasses the persisted default filters, but only
   after the file passes the ephemeral filters.
4. Without an override, a file must also pass both persisted default
   filters: generated files are hidden unless `show_generated`, and
   files with an extension in `hidden_extensions` are hidden.

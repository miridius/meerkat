# File filter panel

A collapsible panel in normal page flow, rendered above the diff body
and spanning the width of the page's content area. It lists every
file in the diff with controls to narrow, hide, or focus the main
file list.

## Toggle

Hidden by default. The toolbar's `☰ Files` button toggles it via
`toolbar.toggle_files_panel`. State lives on the LV's
`files_panel_open` socket assign (ephemeral, NOT persisted).

The `.review-body` always has one column
(`grid-template-columns: 1fr`); opening the panel does not change
the diff body's width. Every time the panel opens, the server pushes
a `scroll-into-view` event for the element with id `file-filter`,
and the client smoothly scrolls the panel to the top of the viewport
(`block: "start"`). The toolbar holding the `☰ Files` button is
sticky, so the button is reachable from anywhere on the page.

## Panel contents

Top to bottom:

1. **Title row**: `Files (visible_count of total_count)`, where
   `visible_count` is the number of files shown in the main file list
   after applying all rules in **Composition**, and `total_count` is
   the number of files in the diff, plus `Hide matched` / `Show matched`
   (one toggle whose label depends on whether every currently-filtered
   file is visible) and `Show all` (visible when `only_file_index != nil`
   OR any `file_overrides` entry is set; clears overrides).
2. **Filter input**: a debounced (50ms) `phx-change="filter.set_input"`
   text box. Filters the panel's list AND the main file list by
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

- A file-visibility checkbox with tooltip `Show / hide <file> in the
  diff list`, checked when the file is visible. Unticking a visible
  file records a `:hide` override in `state.file_overrides`; ticking
  a hidden file records a `:show` override. If another file is being
  shown alone (`only`), ticking a hidden file also clears that filter.
  The main list then returns to every file still allowed by the
  hidden-extension and generated-file filters, per-file overrides,
  and filter text. This is not an approval checkbox; files are
  approved only with the per-file checkbox in the main file list.
- The file's status, shown as a coloured dot whose tooltip names
  the status.
- The file's name is a link showing its full path on one line with no
  truncation; the directory part is dimmed and the base name has
  medium weight (`font-weight: 500`), not bold.
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
  the per-file Approved checkbox in the main file list; the panel's
  rows have no approval checkbox.

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

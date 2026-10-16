# File filter dropdown

A dropdown that opens from the sticky toolbar's `☰ Files` button and
sits over the review, just below the toolbar's left end. It lists
every file in the diff as a folder tree, with controls to narrow,
hide, or focus the main file list, and jumps to a file when its name
is picked.

## Open and close

Closed by default. The `☰ Files` button toggles it via
`toolbar.toggle_files_panel` and reports its state in
`aria-expanded`. State lives on the LV's `files_panel_open` socket
assign (ephemeral, NOT persisted).

The dropdown takes no room in the page: the review does not move or
change width when it opens, and the page does not scroll. It stays
below the toolbar while the page scrolls, below its last row when a
narrow window wraps it, and it is drawn over
everything else on the page, the decision footer included. It is no
taller than the space between the toolbar and the bottom of the
viewport; a longer tree scrolls inside it while its title row, filter
box and chips stay put.

Its width fits its widest row, so the longest file or folder name
sets it, up to the toolbar's width less its padding; a wider tree
scrolls sideways inside it. Rows narrower than
the widest keep their buttons in a column at the dropdown's right.

It closes (`files.close`) on:

- **Escape**, from anywhere on the page. Focus returns to the
  `☰ Files` button.
- **A click outside it.** The `☰ Files` button is not outside it, so
  clicking that button while open just closes it.
- **Picking a file** (see [File rows](#per-entry-affordances)).

## Keyboard

Opening moves focus to the filter box. Every control in the dropdown
is a native button, checkbox or text box, so Tab and Shift+Tab move
through them and Enter or Space works them. Enter in the filter box
applies its text (`phx-submit="filter.set_input"`) rather than
submitting the form natively, which would reload the page and add a
history entry. The `only` and
`hide *.<ext>` buttons, shown on hover, also show while a control in
their row has keyboard focus.

## Folder tree

Like GitHub's file tree:

- Rows show only names: a folder row shows the folder's name, a file
  row the file's base name. Each row's tooltip gives the full path.
  Rows are indented by depth.
- In each folder, subfolders come first, then files, each in
  alphabetical order. The diff below keeps git's order.
- A folder whose only child is a single folder shares its row with
  it, named with both: `lib/meerkat_web/live`.
- Clicking a folder row (`files.toggle_dir`) collapses or expands it;
  its caret points right when collapsed and down when expanded, and
  the row reports its state in `aria-expanded`. Every folder starts
  expanded. Collapsed folders are kept in the LV's `collapsed_dirs`
  assign (ephemeral, per tab), so they stay collapsed when the
  dropdown closes and reopens.
- While the filter box has text, the tree holds only matching files
  and their folders, and every folder starts expanded, so no match
  hides in a folder collapsed beforehand. A folder clicked while
  filtering collapses until the filter text changes; these folders
  are kept apart, in `filter_collapsed_dirs`. Clearing the filter
  restores the folders collapsed without one.

## Panel contents

Top to bottom:

1. **Title row**: `Files (visible_count of total_count)` plus
   `Hide matched` / `Show matched` (one toggle whose label depends
   on whether every currently-filtered file is visible) and
   `Show all` (visible when `only_file_index != nil` OR any
   `file_overrides` entry is set; clears overrides).
   `visible_count` is the number of files the main file list shows
   after all rules in **Composition**; `total_count` is the number
   of files in the diff.
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
5. **Folder tree**: one row per file matching the filter, under its
   folders (see [Folder tree](#folder-tree)).

## Per-entry affordances

Each file row in the tree shows:

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
- The file's base name, on one line with no truncation, in medium
  weight (`font-weight: 500`), not bold. Clicking it, or Enter or
  Space while it has focus, picks the file (`files.pick`): the
  dropdown closes, the page smoothly scrolls the file's section to
  the top of the viewport below the sticky toolbar, and focus moves
  to that section's header row. Picking adds no browser history
  entry, since an extra entry would stop the browser closing the
  review tab after a decision. Picking a file the main list hides
  closes the dropdown without scrolling and moves focus to the
  `☰ Files` button.
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

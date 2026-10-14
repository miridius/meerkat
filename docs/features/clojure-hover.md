# Clojure hover

In a Clojure diff (`.clj`, `.cljc`, `.cljs`, `.edn`), resting the
pointer on a symbol shows the docs and source of the var it names.

## Trigger

- Resting the pointer about 0.4 s on a symbol in a code cell opens
  the popup below it. Moving to another symbol and resting there
  replaces it.
- The popup stays open while the pointer is over the symbol or the
  popup, and closes shortly after the pointer leaves both.
- A plain click still selects text, as before; the line-number
  gutter still starts comment drags.
- A symbol meerkat can't resolve, or whose definition it can't find,
  opens nothing.

## Which side answers

The row's own side: an old (removed) row resolves against the old
text of the diff's files, and a new or context row against the new
text. In split view the column hovered picks the side. The old side
is the review's base. The new side is what meerkat reviews: the
index for staged reviews, the head ref for ranges and PRs, which is
not necessarily the worktree.

## Popup

Top to bottom:

1. The var's qualified name (`ns/name`), marked `macro` for a macro,
   and where it is defined (repo path, or jar and entry) with its line.
2. Its signature: one line per arglist.
3. Its docstring, as plain text with line breaks kept.
4. Its source, highlighted with the diff's own highlighter, theme
   and font size. Source longer than 20 lines shows its first 20
   lines with a `Show all N lines` button that expands it in place.

## Where definitions come from

meerkat runs clj-kondo itself and keeps no long-lived process. It
passes `--cache false`, so it writes nothing into the reviewed repo.
It runs kondo from the repo root, so the repo's `.clj-kondo` config
applies.

- **Diff files.** Each side's changed Clojure files are analysed from
  that side's text.
- **The rest of the project.** One kondo pass over the worktree's
  top-level directories that hold tracked Clojure files, untracked
  files in them included. A file in the diff is answered from the
  side's text, never from the worktree.
- **Dependencies.** On the first hover of a var from a namespace not
  in the project, meerkat finds the namespace's file on the classpath,
  analyses it, and keeps the result for the rest of the review. Docs and source come from that file.
- **Classpath.** meerkat reads only what the user's tooling already
  computed: the newest `.cpcache/*.cp` in the repo root, else the
  `:classpath` in clojure-lsp's `.lsp/.cache/db.transit.json`. It runs
  no classpath command. With neither, dependency vars show nothing.

## Indexing

Indexing starts in the background when a review page opens, only for
reviews that contain a Clojure file. A hover made before indexing
finishes waits for it. All tabs of a review share one index.

## clj-kondo missing

When `clj-kondo` is not on `PATH`, hover is off, and a review with a
Clojure file shows the toolbar note `Clojure hover off: clj-kondo not
found`.

## Not covered

Jump to definition, namespaces and keywords, and locals.

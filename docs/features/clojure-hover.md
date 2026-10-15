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

The header is two tabs. The popup opens on Source for a var defined
in a file inside the repo, and on Docs for one from a dependency: a
jar, or a directory outside the repo. The selected tab is marked by a
subtle background, not the accent colour.

- **Docs**, labelled with the var's qualified name (`ns/name`), marked
  `macro` for a macro: its signature, one line per arglist, then its
  docstring as plain text with line breaks kept, or `No docstring`.
- **Source**, labelled with where the var is defined (repo path, or
  jar and entry) and its line: its whole source, highlighted with the
  diff's own highlighter, theme and font size.

The popup opens below the symbol, unless below has less room than 60%
of the window and above has more. It stays on that side, at most 60%
of the window tall, and content larger than it scrolls inside it.
Above the symbol, it keeps its bottom edge just above the symbol. It
starts at the symbol's left edge, moved left as far as it must to
stay inside the window. Dragging its bottom-right corner resizes it,
up to the window's size, and it then stays where it is.

## Where definitions come from

meerkat runs clj-kondo itself and keeps no long-lived process. It
passes `--cache false`, so it writes nothing into the reviewed repo.
It runs kondo from the repo root, so the repo's `.clj-kondo` config
applies.

- **Diff files.** Each side's changed Clojure files are analysed from
  that side's text. Nothing on disk holds this: kondo's cache records
  no usages, so not which var a symbol names, and the old side was
  never linted.
- **Other namespaces.** On the first hover of a var from a namespace
  no diff file defines, meerkat finds the namespace's file, analyses
  that one file, and keeps the result for the rest of the review.
  Docs and source come from that file. A file in the diff is answered
  from the side's text, never from disk.
- **Finding the file.** First the file the user's own clj-kondo runs
  recorded for the namespace in
  `.clj-kondo/.cache/v1/<lang>/<ns>.transit.json`, unless it is in a
  jar: kondo's cache keeps a jar's entries after the classpath moves
  to a newer version. Then the classpath. The cache holds no
  docstrings, arglists or form ends, so the file is still analysed.
- **Classpath.** meerkat reads only what the user's tooling already
  computed: the newest `.cpcache/*.cp` in the repo root, else the
  `:classpath` in clojure-lsp's `.lsp/.cache/db.transit.json`. It runs
  no classpath command. With neither, only namespaces kondo's cache
  names answer.
- **Language.** A `.clj` or `.cljc` file looks for `clj` then `cljc`
  namespaces; a `.cljs` file for `cljs`, `cljc`, then `clj`, for
  macros.

## Indexing

Analysing the diff files starts in the background when a review page
opens, only for reviews that contain a Clojure file. A hover made
before it finishes waits for it. All browser tabs of a review share
one index.

## clj-kondo missing

When `clj-kondo` is not on `PATH`, hover is off, and a review with a
Clojure file shows the toolbar note `Clojure hover off: clj-kondo not
found`.

## Not covered

Jump to definition, namespaces and keywords, and locals.

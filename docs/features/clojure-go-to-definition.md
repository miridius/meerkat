# Clojure go to definition

In a Clojure diff, Cmd-click (Ctrl-click off macOS) on a symbol jumps
to its definition, as in Cursive and VS Code. It finds definitions the
way [hover](clojure-hover.md) does, on the same side, and is off when
hover is.

## Trigger

- Cmd-click (Ctrl-click off macOS) on a symbol in a code cell jumps to
  its definition. A plain click still selects text.
- Holding Cmd (Ctrl) with the pointer on a symbol that resolves
  underlines it and shows a pointer cursor.
- The hover popup's header has a `Go to` link that jumps to the var it
  shows.
- A symbol meerkat can't resolve shows a brief `No definition found`
  note by the pointer. A symbol defined only on the other side of the
  diff does nothing, as hover shows nothing for it.

## What resolves

- **Vars**: as hover finds them.
- **Locals**: a local binding, such as from `let`, `loop`, `fn`
  parameters or destructuring, in the same file.
- **Namespaces**: a namespace symbol, such as in a `:require`, jumps to
  its file's `ns` form, picking among `.clj`, `.cljc` and `.cljs` files
  in hover's language order.
- **Spec keywords**: a keyword with an `s/def` (`clojure.spec.alpha` or
  `cljs.spec.alpha`) jumps to that `s/def`. meerkat looks in the side's
  diff files, then in the keyword's namespace's file, then in the
  repo's other Clojure files that mention the keyword's name, as the
  side holds them, finding `s/def`s written with an alias too. It keeps
  what it finds for the rest of the review.

## Where it lands

- **A diff file**: the diff scrolls the definition's line on that side
  into view and flashes it. A file that is filtered out or collapsed
  is shown first, as a moved-code arrow shows it, and a line hidden by
  folded context is revealed by expanding the file's context. A jump
  from a file view to a diff file closes the file view.
- **Any other file**, in the repo or a dependency: a read-only file
  view opens over the diff. It shows the whole file as reviewed: a
  repo file as the jump's side holds it (the base for the old side;
  for the new side the index for staged reviews, the head ref for
  ranges and PRs); a dependency's file as its jar or directory holds
  it. It is highlighted with the diff's highlighter, theme and font
  size, with line numbers, and scrolled to the definition in that text,
  whose line is flashed. Its header names the file. When that text
  doesn't hold the file or doesn't define the symbol, as when the
  worktree's copy hover read differs from the reviewed one, the jump
  shows `No definition found`. Hover and go to definition work in it,
  on the side the jump came from, against the text it shows. A jump to
  the file it already shows scrolls within it.

## Getting back

Jumps add no browser history entries, so the review tab still closes
itself after a decision.

- **`Esc`** steps back one jump, to where it started: the file view it
  came from, or the diff scrolled back to the line it showed. Pressing
  it again steps back through earlier jumps. It does so only when no popup,
  form or dropdown is open and focus isn't in a text field.
- **A click outside the file view**, or its close button, closes it,
  back to the diff where the jump that opened it started. `Esc` then
  steps back through the jumps before that one.

Stepping back undoes nothing a jump revealed: a file it showed or
expanded stays as the jump left it.

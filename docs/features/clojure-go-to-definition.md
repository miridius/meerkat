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
- **Locals**: a `let`, `fn` or destructuring binding, in the same file.
- **Namespaces**: a namespace symbol, such as in a `:require`, jumps to
  its file's `ns` form.
- **Spec keywords**: a keyword with an `s/def` (`clojure.spec.alpha` or
  `cljs.spec.alpha`) in the project jumps to that `s/def`. meerkat looks
  in the side's diff files, then in the keyword's namespace's file, then
  in the repo's other Clojure files whose text holds a `def` of it.

## Where it lands

- **A diff file**: the diff scrolls the definition's line on that side
  into view and flashes it. A file the filter hides or that is collapsed
  is shown, and a line hidden by folded context is revealed by
  expanding the file's context.
- **Any other file**, in the repo or a dependency jar: a read-only
  file view opens over the diff. It shows the whole file as reviewed:
  a repo file as the jump's side holds it (the base for the old side;
  for the new side the index for staged reviews, the head ref for
  ranges and PRs); a dependency's file as its jar or directory holds
  it. It is highlighted with the diff's highlighter, theme and font
  size, with line numbers, and scrolled to the definition in that text,
  whose line is flashed. Its header names the file. When that text
  doesn't define the symbol, as when the worktree's copy hover read
  differs from the reviewed one, the jump shows `No definition found`. Hover and go to definition work in it, on the
  side the jump came from. `Esc`, or its close button, closes it.

## Getting back

Each jump is a browser history entry. Back returns to where the jump
started: the diff at its scroll position, or the file view it came
from. Forward repeats the jump. `Esc` in the file view goes back to the
diff entry before the first file view.

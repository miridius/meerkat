// Go to definition's jumps (docs/features/clojure-go-to-definition.md):
// to a line of a diff file, revealed however it is hidden, or to a file
// view; and stepping back from them, which adds no browser history, so
// the review tab can still close itself.

import type { CljJump } from "./cljHover";

export type Live = { pushEvent: (event: string, payload: unknown) => void };
export type Side = "old" | "new";

/** The window event that opens the file view, with `{where, line,
 *  side}`, or closes it, with null. A `scrollTop` scrolls the view
 *  there, instead of to the line and flashing it. */
export const VIEW_EVENT = "meerkat-clj-view";

export type View = { where: string; line: number; side: Side; scrollTop?: number };
export type ViewDetail = View | null;

/** Where a jump started: a file view, scrolled as it was; or the diff,
 *  at the window's scroll, with the line clicked, `row`, `top` px from
 *  the window's top. */
export type JumpStart =
	| { view: View & { scrollTop: number } }
	| { x: number; y: number; row?: { fileIndex: number; side: Side; line: number; top: number } };

// Where each jump not yet stepped back from started, the latest last.
const starts: JumpStart[] = [];

/** Jumps to `jump`'s definition, found on `side`, from `start`. */
export function jumpTo(jump: CljJump, side: Side, live: Live, start: JumpStart) {
	starts.push(start);
	const to = jump.to;
	if ("where" in to) {
		openView({ where: to.where, line: to.line, side });
		return;
	}
	openView(null);
	const detail = { fileIndex: to.file_index, side: to.side, lineStart: to.line, lineEnd: to.line, expand: true };
	// A viewer showing the line takes the jump at once; otherwise the
	// server shows the file, and app.js asks again once it renders.
	if (!document.dispatchEvent(new CustomEvent("meerkat-move-jump", { detail, cancelable: true }))) return;
	live.pushEvent("moved.jump", {
		file_index: to.file_index,
		side: to.side,
		line_start: to.line,
		line_end: to.line,
		expand: true,
	});
}

/** Where a jump from diff file `fileIndex`'s `side` line `line`, whose
 *  row is `row`, starts. */
export function diffStart(fileIndex: number, side: Side, line: number, row: Element | null): JumpStart {
	const top = row?.isConnected ? row.getBoundingClientRect().top : undefined;
	return {
		x: window.scrollX,
		y: window.scrollY,
		row: top === undefined ? undefined : { fileIndex, side, line, top },
	};
}

/** Steps back from the latest jump; false when there is none. */
export function stepBack(): boolean {
	const start = starts.pop();
	if (!start) return false;
	restore(start);
	return true;
}

/** Closes the file view, back to the diff where the first jump into it
 *  started. */
export function closeView() {
	let start = starts.pop();
	while (start && "view" in start) start = starts.pop();
	if (start) restore(start);
	else openView(null);
}

// Esc steps back only when nothing else on the page answers it: a
// popup or dropdown, or a text field, such as a comment form's.
const ESC_OWNERS = ".clj-hover-popup, .keys-sheet, #file-filter, .version-popover:not([hidden]), .toolbar-settings[open]";

/** Whether Esc, as `e`, steps back from a jump. */
export function escStepsBack(e: KeyboardEvent): boolean {
	// One press steps back one jump, however long it is held.
	if (e.key !== "Escape" || e.repeat || e.defaultPrevented || starts.length === 0) return false;
	if (document.querySelector(ESC_OWNERS)) return false;
	const focus = document.activeElement as HTMLElement | null;
	return !(focus?.isContentEditable || focus?.matches("input, textarea, select"));
}

function restore(start: JumpStart) {
	if ("view" in start) {
		openView(start.view);
		return;
	}
	openView(null);
	// The jump may have shown or expanded files above where it started,
	// so the line clicked, when it still shows, goes back where it was.
	const row = start.row && rowOf(start.row.fileIndex, start.row.side, start.row.line);
	if (row && start.row) window.scrollBy({ top: row.getBoundingClientRect().top - start.row.top, behavior: "smooth" });
	else window.scrollTo({ left: start.x, top: start.y, behavior: "smooth" });
}

// Diff file `fileIndex`'s row of `side` line `line`, in unified or
// split view.
function rowOf(fileIndex: number, side: Side, line: number): Element | null {
	const num = document
		.getElementById(`file-${fileIndex}`)
		?.querySelector(`[data-line-${side}-num="${line}"], td.diff-line-${side}-num [data-line-num="${line}"]`);
	return num?.closest("tr.diff-line") ?? null;
}

function openView(detail: ViewDetail) {
	window.dispatchEvent(new CustomEvent(VIEW_EVENT, { detail }));
}

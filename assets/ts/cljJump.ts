// Go to definition's jumps (docs/features/clojure-go-to-definition.md):
// to a line of a diff file, revealed however it is hidden, or to a file
// view.

import type { CljJump } from "./cljHover";

type Live = { pushEvent: (event: string, payload: unknown) => void };

/** The window event that opens the file view, with `{where, line,
 *  side}`, or closes it, with null. */
export const VIEW_EVENT = "meerkat-clj-view";

export type ViewDetail = { where: string; line: number; side: "old" | "new" } | null;

/** Jumps to `jump`'s definition, found on `side`. */
export function jumpTo(jump: CljJump, side: "old" | "new", live: Live) {
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

function openView(detail: ViewDetail) {
	window.dispatchEvent(new CustomEvent(VIEW_EVENT, { detail }));
}

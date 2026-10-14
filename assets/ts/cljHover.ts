// Clojure hover (docs/features/clojure-hover.md): finds the character
// under the pointer in a diff code cell, and shapes the popup's source.

/** How long the pointer rests on a symbol before the popup opens. */
export const HOVER_DELAY_MS = 400;

/** Source lines shown before the `Show all` expander. */
export const SOURCE_PREVIEW_LINES = 20;

/** The server's answer for a hovered var (`Meerkat.CljHover.hover/5`). */
export type CljHover = {
	name: string;
	macro: boolean;
	where: string;
	line: number;
	arglists: string[];
	doc: string | null;
	source: string;
};

export type HoverSpot = {
	side: "old" | "new";
	line: number;
	/** 1-based column of the character under the pointer. */
	col: number;
	/** That character's box, to place the popup under. */
	rect: DOMRect;
};

/** A docstring without the indent its later lines carry in the source
 *  (the first line has none). */
export function dedentDoc(doc: string): string {
	const [first, ...rest] = doc.split("\n");
	const indents = rest.filter((l) => l.trim() !== "").map((l) => l.length - l.trimStart().length);
	const cut = indents.length > 0 ? Math.min(...indents) : 0;
	return [first, ...rest.map((l) => l.slice(cut))].join("\n");
}

/** The source to show: all of it, or its first lines while collapsed. */
export function shownSource(
	source: string,
	expanded: boolean,
): { text: string; total: number; collapsed: boolean } {
	const lines = source.split("\n");
	const collapsed = !expanded && lines.length > SOURCE_PREVIEW_LINES;
	return {
		text: collapsed ? lines.slice(0, SOURCE_PREVIEW_LINES).join("\n") : source,
		total: lines.length,
		collapsed,
	};
}

/** The code character at viewport point (x, y) in a diff table, or null
 *  when the point is not over a character of a code line. */
export function spotAt(x: number, y: number): HoverSpot | null {
	const caret = caretAt(x, y);
	if (!caret || caret.node.nodeType !== Node.TEXT_NODE) return null;
	const raw = caret.node.parentElement?.closest(".diff-line-syntax-raw, .diff-line-content-raw");
	const cell = raw?.closest("td");
	if (!raw || !cell) return null;
	const where = lineOf(cell);
	if (!where) return null;

	// The caret sits at the character boundary nearest the point, so the
	// character under it is the one after the caret or the one before.
	const text = caret.node as Text;
	for (const offset of [caret.offset, caret.offset - 1]) {
		if (offset < 0 || offset >= text.length) continue;
		const range = document.createRange();
		range.setStart(text, offset);
		range.setEnd(text, offset + 1);
		const rect = range.getBoundingClientRect();
		if (x < rect.left || x >= rect.right || y < rect.top || y >= rect.bottom) continue;
		const before = document.createRange();
		before.setStart(raw, 0);
		before.setEnd(text, offset);
		return { ...where, col: before.toString().length + 1, rect };
	}
	return null;
}

function caretAt(x: number, y: number): { node: Node; offset: number } | null {
	if (document.caretPositionFromPoint) {
		const pos = document.caretPositionFromPoint(x, y);
		return pos ? { node: pos.offsetNode, offset: pos.offset } : null;
	}
	const range = document.caretRangeFromPoint?.(x, y);
	return range ? { node: range.startContainer, offset: range.startOffset } : null;
}

// The side and line number of a code cell, read from the number cell
// before it. Split view's number cell holds one number; unified view's
// holds an old and a new one, and a row with a new number reads as new.
function lineOf(cell: HTMLTableCellElement): { side: "old" | "new"; line: number } | null {
	const num = cell.previousElementSibling;
	if (!num) return null;
	if (cell.classList.contains("diff-line-content")) {
		for (const side of ["new", "old"] as const) {
			const line = Number(num.querySelector(`[data-line-${side}-num]`)?.getAttribute(`data-line-${side}-num`));
			if (line > 0) return { side, line };
		}
		return null;
	}
	const side = cell.classList.contains("diff-line-old-content") ? "old" : "new";
	const line = Number(num.querySelector("[data-line-num]")?.getAttribute("data-line-num"));
	return line > 0 ? { side, line } : null;
}

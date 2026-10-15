// Clojure hover (docs/features/clojure-hover.md): finds the character
// under the pointer in a diff code cell, places the popup, and shapes
// its docstring.

/** How long the pointer rests on a symbol before the popup opens. */
export const HOVER_DELAY_MS = 400;

/** The server's answer for a hovered var (`Meerkat.CljHover.hover/5`). */
export type CljHover = {
	name: string;
	macro: boolean;
	where: string;
	/** Defined in a file inside the repo, not a dependency's. */
	in_repo: boolean;
	line: number;
	arglists: string[];
	doc: string | null;
	source: string;
};

/** The tab the popup opens on: the source of the repo's own code, the
 *  docs of a dependency's. */
export function openingTab(hover: CljHover): "doc" | "source" {
	return hover.in_repo ? "source" : "doc";
}

export type HoverSpot = {
	side: "old" | "new";
	line: number;
	/** 1-based column of the character under the pointer. */
	col: number;
	/** That character's box, to place the popup under. */
	rect: DOMRect;
};

/** A symbol's box, in the window, and the page's scroll when it was
 *  measured: together they place the popup on the page, however far
 *  the page has scrolled since. */
export type HoverAnchor = {
	rect: Pick<DOMRect, "top" | "bottom" | "left">;
	scrollX: number;
	scrollY: number;
};

/** `anchor` measured again at the page's scroll `scrollX`, `scrollY`:
 *  the same place on the page, where the window now shows it. */
export function rescrolled(anchor: HoverAnchor, scrollX: number, scrollY: number): HoverAnchor {
	const dx = anchor.scrollX - scrollX;
	const dy = anchor.scrollY - scrollY;
	const { top, bottom, left } = anchor.rect;
	return { rect: { top: top + dy, bottom: bottom + dy, left: left + dx }, scrollX, scrollY };
}

/** Whether the answer `hover`, for a hover on `row` (`side:line`), leaves
 *  the shown popup where it is: only when it names the popup's var and
 *  the popup was opened from that row. Another row, or the other side's,
 *  moves the popup there. */
export function keepsPopup(
	shown: { hover: CljHover; row: string } | null,
	row: string,
	hover: CljHover | null,
): boolean {
	return hover !== null && shown?.row === row && sameVar(hover, shown.hover);
}

function sameVar(a: CljHover, b: CljHover): boolean {
	return a.name === b.name && a.where === b.where && a.line === b.line;
}

/** A docstring without the indent its later lines carry in the source
 *  (the first line has none). */
export function dedentDoc(doc: string): string {
	const [first, ...rest] = doc.split("\n");
	const indents = rest.filter((l) => l.trim() !== "").map((l) => l.length - l.trimStart().length);
	const cut = indents.length > 0 ? Math.min(...indents) : 0;
	return [first, ...rest.map((l) => l.slice(cut))].join("\n");
}

/** Space kept between the popup and the symbol it describes. */
export const POPUP_GAP = 4;
/** Space kept between the popup and the window's edges. */
export const POPUP_MARGIN = 8;

/** The side of a symbol spanning viewport rows `top`..`bottom` the popup
 *  opens on, and the tallest it may open there: below, unless below has
 *  less room than 60% of the window and above has more. */
export function popupSide(
	top: number,
	bottom: number,
	viewHeight: number,
): { above: boolean; cap: number } {
	const below = viewHeight - bottom - POPUP_GAP - POPUP_MARGIN;
	const above = top - POPUP_GAP - POPUP_MARGIN;
	const full = viewHeight * 0.6;
	const isAbove = below < full && above > below;
	return { above: isAbove, cap: Math.min(full, isAbove ? above : below) };
}

/** The viewport x of a popup `width` wide for a symbol at `left`: at the
 *  symbol, moved left as far as it must to stay inside the window. */
export function popupLeft(left: number, width: number, viewWidth: number): number {
	return Math.max(POPUP_MARGIN, Math.min(left, viewWidth - width - POPUP_MARGIN));
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

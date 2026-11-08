/** Vertical column rulers, shared by the diff and the suggestion editor.
 *  A ruler is a 1px line just after its column, drawn as a background
 *  image so it scrolls with the text. */

/** CSS `background-image` value drawing a ruler after each of `columns`,
 *  measured in `ch` from `offset` (a CSS length: where the text starts
 *  in the element), the element's full height. */
export function rulerBackground(columns: number[], offset: string, color: string): string {
	if (columns.length === 0) return "none";
	return columns.map((col) => rulerLine(col, offset, color)).join(", ");
}

/** CSS `background` value drawing each of `columns`' rulers on text that
 *  wraps every `perRow` columns, rows `1lh` tall: only on the row its
 *  column falls on, at its place in that row. Rows after the first are
 *  inset 1px at top and bottom: snapped to device pixels, a row would
 *  otherwise leave a dot on the row before or after it, or below a line
 *  too short to reach it. */
export function wrappedRulerBackground(columns: number[], perRow: number, offset: string, color: string): string {
	if (columns.length === 0) return "none";
	return columns
		.map((col) => {
			const row = Math.ceil(col / perRow) - 1;
			const tile = row === 0 ? "0 0 / 100% 1lh" : `0 calc(${row}lh + 1px) / 100% calc(1lh - 2px)`;
			return `${rulerLine(col - row * perRow, offset, color)} ${tile} no-repeat`;
		})
		.join(", ");
}

function rulerLine(col: number, offset: string, color: string): string {
	const at = `calc(${offset} + ${col}ch)`;
	const end = `calc(${offset} + ${col}ch + 1px)`;
	return `linear-gradient(to right, transparent ${at}, ${color} ${at}, ${color} ${end}, transparent ${end})`;
}

/** The columns whose ruler fits within `widthPx`, for text starting
 *  `offsetPx` in and characters `chPx` wide. */
export function fittingColumns(
	columns: number[],
	widthPx: number,
	offsetPx: number,
	chPx: number,
): number[] {
	return columns.filter((col) => offsetPx + col * chPx + 1 <= widthPx);
}

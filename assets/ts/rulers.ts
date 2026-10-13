/** Vertical column rulers, shared by the diff and the suggestion editor.
 *  A ruler is a 1px line just after its column, drawn as a background
 *  image so it spans its element's full height and scrolls with the
 *  text. */

/** CSS `background-image` value drawing a ruler after each of `columns`,
 *  measured in `ch` from `offset` (a CSS length: where the text starts
 *  in the element). */
export function rulerBackground(columns: number[], offset: string, color: string): string {
	if (columns.length === 0) return "none";
	return columns
		.map((col) => {
			const at = `calc(${offset} + ${col}ch)`;
			const end = `calc(${offset} + ${col}ch + 1px)`;
			return `linear-gradient(to right, transparent ${at}, ${color} ${at}, ${color} ${end}, transparent ${end})`;
		})
		.join(", ");
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

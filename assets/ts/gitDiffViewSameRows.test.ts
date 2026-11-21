import { describe, expect, test } from "bun:test";

// The row-list check patches/@git-diff-view__svelte.patch adds to the diff
// views, so a view skips rewriting rows that have not changed.
const { sameRows } = (await import(
	new URL("utils/utils.js", import.meta.resolve("@git-diff-view/svelte")).href
)) as { sameRows: (a: { index: number }[], b: { index: number }[]) => boolean };

const rows = (...indexes: number[]) => indexes.map((index) => ({ index, lineNumber: index + 1 }));

describe("patched @git-diff-view/svelte sameRows", () => {
	test("rows with the same indexes in the same order are the same", () => {
		expect(sameRows(rows(0, 1, 5), rows(0, 1, 5))).toBe(true);
		expect(sameRows([], [])).toBe(true);
	});

	test("a row added or dropped makes them differ", () => {
		expect(sameRows(rows(0, 1), rows(0, 1, 2))).toBe(false);
		expect(sameRows(rows(0, 1, 2), rows(0, 1))).toBe(false);
	});

	test("as many rows with other indexes differ", () => {
		expect(sameRows(rows(0, 1, 2), rows(0, 1, 3))).toBe(false);
		expect(sameRows(rows(0, 1, 2), rows(2, 1, 0))).toBe(false);
	});
});

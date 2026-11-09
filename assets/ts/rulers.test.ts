import { describe, expect, test } from "bun:test";
import { fittingColumns, rulerBackground, wrappedRulerBackground } from "./rulers";

describe("rulerBackground", () => {
	test("draws a 1px line after each column, from the offset", () => {
		expect(rulerBackground([80, 110], "2em", "red")).toBe(
			"linear-gradient(to right, transparent calc(2em + 80ch), red calc(2em + 80ch), red calc(2em + 80ch + 1px), transparent calc(2em + 80ch + 1px)), " +
				"linear-gradient(to right, transparent calc(2em + 110ch), red calc(2em + 110ch), red calc(2em + 110ch + 1px), transparent calc(2em + 110ch + 1px))",
		);
	});

	test("draws nothing without columns", () => {
		expect(rulerBackground([], "2em", "red")).toBe("none");
	});
});

describe("wrappedRulerBackground", () => {
	test("draws each ruler on the row its column falls on, at its place in that row", () => {
		// 50 columns a row: 40 and 50 at the first row's end, 51 at the end
		// of the second's first column, 110 on the third.
		const line = (col: number) =>
			`linear-gradient(to right, transparent calc(2em + ${col}ch), red calc(2em + ${col}ch), red calc(2em + ${col}ch + 1px), transparent calc(2em + ${col}ch + 1px))`;
		expect(wrappedRulerBackground([40, 50, 51, 110], 50, "2em", "red")).toBe(
			`${line(40)} 0 0 / 100% 1lh no-repeat, ` +
				`${line(50)} 0 0 / 100% 1lh no-repeat, ` +
				`${line(1)} 0 calc(1lh + 1px) / 100% calc(1lh - 2px) no-repeat, ` +
				`${line(10)} 0 calc(2lh + 1px) / 100% calc(1lh - 2px) no-repeat`,
		);
	});

	test("draws nothing without columns", () => {
		expect(wrappedRulerBackground([], 50, "2em", "red")).toBe("none");
	});
});

describe("fittingColumns", () => {
	test("keeps a ruler whose whole 1px line fits in the width", () => {
		// 26px offset + 80 columns of 8px = 666px, plus the 1px line.
		expect(fittingColumns([80, 110], 667, 26, 8)).toEqual([80]);
		expect(fittingColumns([80, 110], 666, 26, 8)).toEqual([]);
		expect(fittingColumns([80, 110], 907, 26, 8)).toEqual([80, 110]);
	});
});

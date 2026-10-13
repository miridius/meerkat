import { describe, expect, test } from "bun:test";
import { fittingColumns, rulerBackground } from "./rulers";

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

describe("fittingColumns", () => {
	test("keeps a ruler whose whole 1px line fits in the width", () => {
		// 26px offset + 80 columns of 8px = 666px, plus the 1px line.
		expect(fittingColumns([80, 110], 667, 26, 8)).toEqual([80]);
		expect(fittingColumns([80, 110], 666, 26, 8)).toEqual([]);
		expect(fittingColumns([80, 110], 907, 26, 8)).toEqual([80, 110]);
	});
});

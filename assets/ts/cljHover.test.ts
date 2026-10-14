import { describe, expect, test } from "bun:test";
import { dedentDoc, SOURCE_PREVIEW_LINES, shownSource } from "./cljHover";

describe("dedentDoc", () => {
	test("removes the indent the later lines share, keeping deeper indents", () => {
		expect(dedentDoc("Does a thing.\n  More.\n\n    * nested\n  End.")).toBe(
			"Does a thing.\nMore.\n\n  * nested\nEnd.",
		);
	});

	test("leaves a one-line or unindented docstring alone", () => {
		expect(dedentDoc("  One line.")).toBe("  One line.");
		expect(dedentDoc("A\nB")).toBe("A\nB");
	});
});

describe("shownSource", () => {
	const lines = (n: number) => Array.from({ length: n }, (_, i) => `l${i + 1}`).join("\n");

	test("shows short source whole", () => {
		const source = lines(SOURCE_PREVIEW_LINES);
		expect(shownSource(source, false)).toEqual({ text: source, total: 20, collapsed: false });
	});

	test("collapses long source to its first lines until expanded", () => {
		const source = lines(SOURCE_PREVIEW_LINES + 1);
		expect(shownSource(source, false)).toEqual({
			text: lines(SOURCE_PREVIEW_LINES),
			total: 21,
			collapsed: true,
		});
		expect(shownSource(source, true)).toEqual({ text: source, total: 21, collapsed: false });
	});
});

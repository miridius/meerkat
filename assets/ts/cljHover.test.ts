import { describe, expect, test } from "bun:test";
import { dedentDoc, popupLeft, popupSide } from "./cljHover";

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

describe("popupSide", () => {
	// A 900px window: 60% is 540px; the gap and margin take 12px.
	test("opens below, capped at 60% of the window, when below has that room", () => {
		expect(popupSide(100, 120, 900)).toEqual({ above: false, cap: 540 });
		expect(popupSide(336, 348, 900)).toEqual({ above: false, cap: 540 });
	});

	test("opens above when below is short of 60% and above has more room", () => {
		// The symbol near the window's bottom: 112px below, 749px above.
		expect(popupSide(761, 776, 900)).toEqual({ above: true, cap: 540 });
		expect(popupSide(400, 700, 900)).toEqual({ above: true, cap: 388 });
	});

	test("stays below, capped to the room there, when above has no more", () => {
		expect(popupSide(300, 600, 900)).toEqual({ above: false, cap: 288 });
	});
});

describe("popupLeft", () => {
	test("sits at the symbol when it fits", () => {
		expect(popupLeft(100, 400, 1280)).toBe(100);
		expect(popupLeft(872, 400, 1280)).toBe(872);
	});

	test("moves left to stay inside the window", () => {
		expect(popupLeft(784, 539, 1280)).toBe(733);
	});

	test("keeps the margin on the left when wider than the window", () => {
		expect(popupLeft(300, 1300, 1280)).toBe(8);
	});
});

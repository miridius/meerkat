import { describe, expect, test } from "bun:test";
import { type CljHover, dedentDoc, keepsPopup, openingTab, popupLeft, popupSide, rescrolled } from "./cljHover";

describe("rescrolled", () => {
	test("moves the box by how far the page scrolled since it was measured", () => {
		const anchor = { rect: { top: 700, bottom: 720, left: 50 }, scrollX: 0, scrollY: 100 };
		expect(rescrolled(anchor, 30, 600)).toEqual({
			rect: { top: 200, bottom: 220, left: 20 },
			scrollX: 30,
			scrollY: 600,
		});
	});
});

describe("openingTab", () => {
	const hover = (in_repo: boolean): CljHover => ({
		name: "a/f",
		macro: false,
		where: "src/a.clj",
		in_repo,
		line: 1,
		arglists: [],
		doc: null,
		source: "(defn f [])",
	});

	test("opens the repo's own code on its source, a dependency's on its docs", () => {
		expect(openingTab(hover(true))).toBe("source");
		expect(openingTab(hover(false))).toBe("doc");
	});
});

describe("keepsPopup", () => {
	const hover = (name: string, line = 1): CljHover => ({
		name,
		macro: false,
		where: "src/a.clj",
		in_repo: true,
		line,
		arglists: [],
		doc: null,
		source: "(defn f [])",
	});
	const shown = { hover: hover("a/f"), row: "new:3" };

	test("keeps the popup for its var hovered again on its row", () => {
		expect(keepsPopup(shown, "new:3", hover("a/f"))).toBe(true);
	});

	test("moves it for another line, the other side, or another var", () => {
		expect(keepsPopup(shown, "new:4", hover("a/f"))).toBe(false);
		expect(keepsPopup(shown, "old:3", hover("a/f"))).toBe(false);
		expect(keepsPopup(shown, "new:3", hover("a/g"))).toBe(false);
		expect(keepsPopup(shown, "new:3", hover("a/f", 2))).toBe(false);
		expect(keepsPopup(shown, "new:3", { ...hover("a/f"), where: "src/b.clj" })).toBe(false);
	});

	test("closes it for no answer, and opens one when none is shown", () => {
		expect(keepsPopup(shown, "new:3", null)).toBe(false);
		expect(keepsPopup(null, "new:3", hover("a/f"))).toBe(false);
	});
});

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

import { describe, expect, test } from "bun:test";
import { changesFit, SQUEEZE_STEPS, squeeze } from "./toolbarSqueeze";

describe("squeeze", () => {
	test("takes no step when the content already fits", () => {
		expect(squeeze(() => true)).toEqual([]);
	});

	test("takes steps in order and stops at the first that makes it fit", () => {
		const asked: string[][] = [];
		const taken = squeeze((steps) => {
			asked.push(steps);
			return steps.length === 3;
		});
		expect(taken).toEqual(["version", "files", "conn"]);
		expect(asked).toEqual([[], ["version"], ["version", "files"], ["version", "files", "conn"]]);
	});

	test("takes every step, ending with a wrap, when nothing makes it fit", () => {
		expect(squeeze(() => false)).toEqual(SQUEEZE_STEPS);
		expect(SQUEEZE_STEPS.at(-1)).toBe("wrap");
	});

	test("gives up room in the order the reviewer ranked it", () => {
		expect(SQUEEZE_STEPS).toEqual(["version", "files", "conn", "counts", "view", "title", "base", "head", "wrap"]);
	});
});

describe("changesFit", () => {
	// Nodes are names; the dropdown's are those starting "dd".
	const inDropdown = (node: string) => node.startsWith("dd");
	const attr = (target: string) => ({ type: "attributes", target, addedNodes: [], removedNodes: [] });
	const children = (target: string, addedNodes: string[], removedNodes: string[] = []) => ({
		type: "childList",
		target,
		addedNodes,
		removedNodes,
	});

	test("ignores changes inside the dropdown, and its opening and closing", () => {
		expect(changesFit([attr("dd-row"), children("dd-tree", ["chip"], ["text"])], inDropdown)).toBe(false);
		expect(changesFit([children("wrapper", ["dd-panel"]), children("wrapper", [], ["dd-panel"])], inDropdown)).toBe(
			false,
		);
		expect(changesFit([], inDropdown)).toBe(false);
	});

	test("refits on any change outside the dropdown", () => {
		expect(changesFit([attr("dd-row"), attr("chip")], inDropdown)).toBe(true);
		expect(changesFit([children("toolbar", ["dd-panel", "badge"])], inDropdown)).toBe(true);
		expect(changesFit([children("toolbar", [], ["badge"])], inDropdown)).toBe(true);
		expect(changesFit([{ type: "characterData", target: "pill", addedNodes: [], removedNodes: [] }], inDropdown)).toBe(
			true,
		);
	});
});

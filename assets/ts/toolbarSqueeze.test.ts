import { describe, expect, test } from "bun:test";
import { SQUEEZE_STEPS, squeeze } from "./toolbarSqueeze";

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

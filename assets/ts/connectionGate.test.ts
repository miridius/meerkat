import { describe, expect, test } from "bun:test";
import { gateVerdict } from "./connectionGate";

describe("gateVerdict", () => {
	test("cancels clicks, edits and submits anywhere", () => {
		for (const type of ["click", "auxclick", "dblclick", "beforeinput", "submit", "drop"] as const) {
			for (const target of ["text", "control", "other"] as const) {
				expect(gateVerdict({ type }, target, true)).toBe("cancel");
			}
		}
	});

	test("cancels a press that would move focus, and lets a press select text", () => {
		expect(gateVerdict({ type: "mousedown" }, "control", false)).toBe("cancel");
		expect(gateVerdict({ type: "mousedown" }, "text", false)).toBe("cancel");
		expect(gateVerdict({ type: "mousedown" }, "text", true)).toBe("stop");
		expect(gateVerdict({ type: "mousedown" }, "other", false)).toBe("stop");
		expect(gateVerdict({ type: "pointerdown" }, "control", false)).toBe("stop");
	});

	test("cancels Tab and keys on a control, and keeps find, copy and caret moves", () => {
		expect(gateVerdict({ type: "keydown", key: "Tab" }, "other", false)).toBe("cancel");
		expect(gateVerdict({ type: "keydown", key: "Tab", ctrlKey: true }, "text", true)).toBe("cancel");
		expect(gateVerdict({ type: "keydown", key: " " }, "control", true)).toBe("cancel");
		expect(gateVerdict({ type: "keydown", key: "f", metaKey: true }, "control", true)).toBe("stop");
		expect(gateVerdict({ type: "keydown", key: "c", ctrlKey: true }, "control", true)).toBe("stop");
		expect(gateVerdict({ type: "keydown", key: "ArrowLeft" }, "text", true)).toBe("stop");
		expect(gateVerdict({ type: "keydown", key: "ArrowDown" }, "other", false)).toBe("stop");
		expect(gateVerdict({ type: "keyup", key: " " }, "control", true)).toBe("stop");
	});

	test("only stops releases", () => {
		for (const type of ["pointerup", "mouseup"] as const) {
			expect(gateVerdict({ type }, "control", false)).toBe("stop");
		}
	});
});

import { describe, expect, test } from "bun:test";
import { gateVerdict } from "./connectionGate";

describe("gateVerdict", () => {
	test("cancels clicks, edits and submits anywhere", () => {
		for (const type of ["click", "auxclick", "dblclick", "beforeinput", "paste", "cut", "submit", "drop"] as const) {
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

	test("cancels only Tab at keydown", () => {
		expect(gateVerdict({ type: "keydown", key: "Tab" }, "other", false)).toBe("cancel");
		expect(gateVerdict({ type: "keydown", key: "Tab" }, "text", true)).toBe("cancel");
		expect(gateVerdict({ type: "keydown", key: " " }, "control", true)).toBe("stop");
		expect(gateVerdict({ type: "keydown", key: "c" }, "control", true)).toBe("stop");
		expect(gateVerdict({ type: "keydown", key: "ArrowLeft" }, "text", true)).toBe("stop");
		expect(gateVerdict({ type: "keyup", key: " " }, "control", true)).toBe("stop");
	});

	test("only stops releases", () => {
		for (const type of ["pointerup", "mouseup"] as const) {
			expect(gateVerdict({ type }, "control", false)).toBe("stop");
		}
	});
});

import { describe, expect, test } from "bun:test";
import { slowdown } from "./budget.js";

describe("slowdown", () => {
	test("is the load per core", () => {
		expect(slowdown(36, 18)).toBe(2);
	});

	test("is never below 1 on a lightly loaded machine", () => {
		expect(slowdown(4, 18)).toBe(1);
	});

	test("is capped at 4, so a hang still fails", () => {
		expect(slowdown(250, 18)).toBe(4);
	});
});

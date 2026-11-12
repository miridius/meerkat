import { expect, test } from "bun:test";
import { verdict } from "./hex-audit";

test("passes a clean audit", () => {
	expect(verdict("", 0)).toEqual({ code: 0 });
});

test("fails when mix hex.audit fails", () => {
	expect(verdict("", 1)).toEqual({ code: 1 });
	expect(verdict("", null)).toEqual({ code: 1 });
});

test("fails a passing audit when Hex could not fetch a record", () => {
	const { code, why } = verdict("Failed to fetch record for bandit from registry (using cache instead)\n", 0);
	expect(code).toBe(1);
	expect(why).toContain("the audit is incomplete");
});

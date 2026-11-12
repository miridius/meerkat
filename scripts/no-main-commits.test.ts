import { expect, test } from "bun:test";
import { judge } from "./no-main-commits";

test("refuses a commit on main", () => {
	const r = judge({ status: 0, out: "main\n" });
	expect(r.status).toBe(1);
	expect(r.err[0]).toBe("ERROR: Direct commits to 'main' are blocked.");
});

// An orphan branch's root commit is on a branch that has no commit yet.
test("lets a commit on any other branch through", () => {
	expect(judge({ status: 0, out: "feature\n" })).toEqual({ status: 0, err: [] });
	expect(judge({ status: 0, out: "mainline\n" })).toEqual({ status: 0, err: [] });
});

// symbolic-ref exits 1 for a detached HEAD.
test("lets a commit on a detached HEAD through", () => {
	expect(judge({ status: 1, out: "" })).toEqual({ status: 0, err: [] });
});

test("refuses the commit when git cannot tell the branch", () => {
	const r = judge({ status: 128, out: "" });
	expect(r.status).toBe(1);
	expect(r.err[0]).toBe("ERROR: could not determine current branch — refusing commit.");
});

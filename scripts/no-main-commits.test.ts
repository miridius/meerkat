import { expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
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

test("run by git on a detached HEAD, lets the commit through", () => {
	const repo = mkdtempSync(join(tmpdir(), "meerkat-no-main-"));
	const env = {
		...Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith("GIT_"))),
		GIT_CONFIG_GLOBAL: join(import.meta.dir, "../test/support/test.gitconfig"),
		GIT_CONFIG_NOSYSTEM: "1",
	};
	const git = (...args: string[]) => {
		if (Bun.spawnSync(["git", ...args], { cwd: repo, env }).exitCode !== 0) throw new Error(`git ${args.join(" ")} failed`);
	};
	try {
		git("init", "-q", "--initial-branch=main");
		git("-c", "user.email=t@t.t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "base");
		git("switch", "-q", "--detach");
		const r = Bun.spawnSync([process.execPath, join(import.meta.dir, "no-main-commits.ts")], { cwd: repo, env });
		expect(r.exitCode).toBe(0);
	} finally {
		rmSync(repo, { recursive: true, force: true });
	}
});

test("refuses the commit when git cannot tell the branch", () => {
	const r = judge({ status: 128, out: "" });
	expect(r.status).toBe(1);
	expect(r.err[0]).toBe("ERROR: could not determine current branch — refusing commit.");
});

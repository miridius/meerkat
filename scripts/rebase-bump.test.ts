import { expect, test } from "bun:test";
import type { Ran } from "./deps-common.ts";
import { Fake } from "./deps-fake.ts";
import { rebaseBump } from "./rebase-bump.ts";

// hook COMMAND CODES STATUS: runs the hook for COMMAND, each command exiting
// with CODES' entry for it, or 0, and git status replying STATUS, and
// returns its status, the commands it ran, those whose output it streamed,
// and what it printed.
async function hook(command: string, codes: Record<string, number> = {}, status: Partial<Ran> = {}) {
	const fake = new Fake();
	fake.sys.prefix = "post-rewrite:";
	for (const [cmd, code] of Object.entries(codes)) fake.on(cmd, { code });
	fake.on("git status --porcelain --untracked-files=no", status);
	const code = await rebaseBump(command, fake.sys);
	const streamed = fake.calls.filter((c) => c.inherit).map((c) => c.cmd);
	return { code, ran: fake.ran, streamed, text: fake.text };
}

const STAGED = { "git diff --cached --quiet": 1 };

test("a rebase that leaves dependencies behind commits their bump on top", async () => {
	const { code, ran, streamed, text } = await hook("rebase", STAGED);
	expect(code).toBe(0);
	// The bump and the commit show their own output.
	expect(streamed).toEqual(ran);
	expect(ran).toEqual([
		"bun scripts/bump-deps.ts",
		"git diff --cached --quiet",
		"git commit -q -m Bump dependencies",
	]);
	expect(text).toBe("post-rewrite: committed the dependency bump on top of the rebase.");
});

test("a rebase while everything is current adds no commit", async () => {
	const { code, ran, text } = await hook("rebase");
	expect(code).toBe(0);
	expect(ran).toEqual(["bun scripts/bump-deps.ts", "git diff --cached --quiet"]);
	expect(text).toBe("");
});

// An amend went through pre-commit.
test("an amend gets no bump", async () => {
	expect(await hook("amend")).toEqual({ code: 0, ran: [], streamed: [], text: "" });
});

test("a rebase whose bump fails is left done, saying so", async () => {
	const { code, ran, text } = await hook("rebase", { "bun scripts/bump-deps.ts": 1 });
	expect(code).toBe(1);
	expect(ran).toEqual(["bun scripts/bump-deps.ts", "git status --porcelain --untracked-files=no"]);
	expect(text).toBe(
		"post-rewrite: scripts/bump-deps.ts failed, so the rebase was left without a dependency bump commit.\n" +
			"  The pre-push gate refuses the push while dependencies are outdated.",
	);
});

test("a git status that fails says the bump's changes may be left, and why", async () => {
	const { code, text } = await hook(
		"rebase",
		{ "bun scripts/bump-deps.ts": 1 },
		{ stderr: "fatal: index file corrupt\n", code: 128 },
	);
	expect(code).toBe(1);
	expect(text).toBe(
		"post-rewrite: scripts/bump-deps.ts failed, so the rebase was left without a dependency bump commit.\n" +
			"  git status failed, so the bump's changes may be left in the worktree:\n" +
			"fatal: index file corrupt\n" +
			"  The pre-push gate refuses the push while dependencies are outdated.",
	);
});

test("a rebase whose bump commit is refused leaves the bump in the worktree, saying so", async () => {
	const { code, text } = await hook(
		"rebase",
		{ ...STAGED, "git commit -q -m Bump dependencies": 1 },
		{ stdout: "M  mix.lock\n" },
	);
	expect(code).toBe(1);
	expect(text).toBe(
		"post-rewrite: the bump could not be committed, so the rebase was left without a dependency bump commit.\n" +
			"  The bump's changes are left in the worktree; `git status` lists them.\n" +
			"  The pre-push gate refuses the push while dependencies are outdated.",
	);
});

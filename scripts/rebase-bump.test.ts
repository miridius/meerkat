import { expect, test } from "bun:test";
import { rebaseBump } from "./rebase-bump.ts";

// hook COMMAND CODES: runs the hook for COMMAND, each command exiting with
// CODES' entry for it, or 0, and returns its status, the commands it ran
// and what it printed.
function hook(command: string, codes: Record<string, number> = {}, status = "") {
	const ran: string[] = [];
	const lines: string[] = [];
	const code = rebaseBump(
		command,
		(cmd) => {
			const line = cmd.join(" ");
			ran.push(line);
			return { code: codes[line] ?? 0, stdout: line.startsWith("git status") ? status : "" };
		},
		(text) => lines.push(text),
		(text) => lines.push(text),
	);
	return { code, ran, text: lines.join("\n") };
}

const STAGED = { "git diff --cached --quiet": 1 };

test("a rebase that leaves dependencies behind commits their bump on top", () => {
	const { code, ran, text } = hook("rebase", STAGED);
	expect(code).toBe(0);
	expect(ran).toEqual([
		"bun scripts/bump-deps.ts",
		"git diff --cached --quiet",
		"git commit -q -m Bump dependencies",
	]);
	expect(text).toBe("post-rewrite: committed the dependency bump on top of the rebase.");
});

test("a rebase while everything is current adds no commit", () => {
	const { code, ran, text } = hook("rebase");
	expect(code).toBe(0);
	expect(ran).toEqual(["bun scripts/bump-deps.ts", "git diff --cached --quiet"]);
	expect(text).toBe("");
});

// An amend went through pre-commit.
test("an amend gets no bump", () => {
	expect(hook("amend")).toEqual({ code: 0, ran: [], text: "" });
});

test("a rebase whose bump fails is left done, saying so", () => {
	const { code, ran, text } = hook("rebase", { "bun scripts/bump-deps.ts": 1 });
	expect(code).toBe(1);
	expect(ran).toEqual(["bun scripts/bump-deps.ts", "git status --porcelain --untracked-files=no"]);
	expect(text).toBe(
		"post-rewrite: scripts/bump-deps.ts failed, so the rebase was left without a dependency bump commit.\n" +
			"  The pre-push gate refuses the push while dependencies are outdated.",
	);
});

test("a rebase whose bump commit is refused leaves the bump in the worktree, saying so", () => {
	const { code, text } = hook("rebase", { ...STAGED, "git commit -q -m Bump dependencies": 1 }, "M  mix.lock\n");
	expect(code).toBe(1);
	expect(text).toBe(
		"post-rewrite: the bump could not be committed, so the rebase was left without a dependency bump commit.\n" +
			"  The bump's changes are left in the worktree; `git status` lists them.\n" +
			"  The pre-push gate refuses the push while dependencies are outdated.",
	);
});

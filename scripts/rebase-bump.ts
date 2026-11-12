// Post-rewrite hook: after a rebase, bumps outdated dependencies and commits
// the bump on top of the rebased commits. A rebase makes its commits without
// the pre-commit hook, so without this a release that came out since they
// were made would reach the pre-push gate unbumped.
//
//   bun scripts/rebase-bump.ts <rewrite command>
//
// Git passes the command that rewrote the commits: `amend` or `rebase`. An
// amend went through the pre-commit hook, so only a rebase is bumped. The
// commit goes through the pre-commit hook too, which checks it. Git ignores
// this hook's exit status, so a failure leaves the rebase done and says so.

import { main, type Sys } from "./deps-common.ts";

// rebaseBump COMMAND SYS: the hook's exit status, printing what it did.
export async function rebaseBump(command: string | undefined, sys: Sys): Promise<number> {
	const run = async (...cmd: string[]) => (await sys.run(cmd, { inherit: true })).code;
	async function fail(what: string): Promise<number> {
		sys.err(`${sys.prefix} ${what}, so the rebase was left without a dependency bump commit.`);
		if ((await sys.run(["git", "status", "--porcelain", "--untracked-files=no"])).stdout)
			sys.err("  The bump's changes are left in the worktree; `git status` lists them.");
		sys.err("  The pre-push gate refuses the push while dependencies are outdated.");
		return 1;
	}

	if (command !== "rebase") return 0;
	if ((await run("bun", "scripts/bump-deps.ts")) !== 0) return fail("scripts/bump-deps.ts failed");
	if ((await run("git", "diff", "--cached", "--quiet")) !== 0) {
		if ((await run("git", "commit", "-q", "-m", "Bump dependencies")) !== 0)
			return fail("the bump could not be committed");
		sys.out(`${sys.prefix} committed the dependency bump on top of the rebase.`);
	}
	return 0;
}

if (import.meta.main) await main("post-rewrite:", (sys) => rebaseBump(process.argv[2], sys));

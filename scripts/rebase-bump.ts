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

// Runs a command, streaming its output, or capturing it with `capture`.
export type Run = (cmd: string[], capture?: boolean) => { code: number; stdout: string };

const realRun: Run = (cmd, capture = false) => {
	const r = Bun.spawnSync(cmd, { stdio: ["ignore", capture ? "pipe" : "inherit", "inherit"] });
	return { code: r.exitCode, stdout: capture ? r.stdout.toString() : "" };
};

// rebaseBump COMMAND RUN: the hook's exit status, printing what it did.
export function rebaseBump(command: string | undefined, run: Run, log = console.log, err = console.error): number {
	function fail(what: string): number {
		err(`post-rewrite: ${what}, so the rebase was left without a dependency bump commit.`);
		if (run(["git", "status", "--porcelain", "--untracked-files=no"], true).stdout)
			err("  The bump's changes are left in the worktree; `git status` lists them.");
		err("  The pre-push gate refuses the push while dependencies are outdated.");
		return 1;
	}

	if (command !== "rebase") return 0;
	if (run(["bun", "scripts/bump-deps.ts"]).code !== 0) return fail("scripts/bump-deps.ts failed");
	if (run(["git", "diff", "--cached", "--quiet"]).code !== 0) {
		if (run(["git", "commit", "-q", "-m", "Bump dependencies"]).code !== 0)
			return fail("the bump could not be committed");
		log("post-rewrite: committed the dependency bump on top of the rebase.");
	}
	return 0;
}

if (import.meta.main) process.exit(rebaseBump(process.argv[2], realRun));

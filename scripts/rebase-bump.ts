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

// A rebase exports GIT_SEQUENCE_EDITOR=: to its hooks. Left set, it would
// override the editor of every interactive rebase the pre-commit checks run,
// such as the tests' own.
const { GIT_SEQUENCE_EDITOR: _, ...env } = process.env;
const run = (cmd: string[]) => Bun.spawnSync(cmd, { env, stdio: ["ignore", "inherit", "inherit"] }).exitCode;

function fail(what: string): never {
	console.error(`post-rewrite: ${what}, so the rebase was left without the dependency bump.`);
	console.error("  The pre-push gate refuses the push while dependencies are outdated.");
	process.exit(1);
}

if (process.argv[2] === "rebase") {
	if (run(["bash", "scripts/bump-deps.sh"]) !== 0) fail("scripts/bump-deps.sh failed");
	if (run(["git", "diff", "--cached", "--quiet"]) !== 0) {
		if (run(["git", "commit", "-q", "-m", "Bump dependencies"]) !== 0) fail("the bump could not be committed");
		console.log("post-rewrite: committed the dependency bump on top of the rebase.");
	}
}

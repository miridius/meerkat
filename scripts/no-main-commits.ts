// Pre-commit hook: refuse commits made directly on `main`.
//
// Feature work, bug fixes, and anything else that'd merit a PR must land on
// a branch that goes through review — not on main. This check catches
// accidental direct-to-main commits (the usual failure mode: finishing a task
// without remembering to branch first).

import type { GitResult } from "./checked-trees";

const PROTECTED_BRANCH = "main";

// The hook's exit status and what it prints to stderr, given what
// `git symbolic-ref --quiet --short HEAD` returned. symbolic-ref names the
// branch even before its first commit, which an orphan branch's root commit
// needs; it exits 1 for a detached HEAD, which is on no branch and so not
// on main.
//
// Fail closed: if git itself can't tell us the branch, refuse the commit
// rather than letting it through silently. A corrupt or unusual git state is
// exactly when a surprise commit to main would be worst.
export function judge(ref: GitResult): { status: number; err: string[] } {
	if (ref.status === 1) return { status: 0, err: [] };
	if (ref.status !== 0)
		return {
			status: 1,
			err: ["ERROR: could not determine current branch — refusing commit.", "(Run `git status` to diagnose.)"],
		};
	if (ref.out.trim() !== PROTECTED_BRANCH) return { status: 0, err: [] };
	return {
		status: 1,
		err: [
			`ERROR: Direct commits to '${PROTECTED_BRANCH}' are blocked.`,
			"Create a branch first:",
			"    git switch -c <branch-name>",
			"    git commit ...",
		],
	};
}

if (import.meta.main) {
	const r = Bun.spawnSync(["git", "symbolic-ref", "--quiet", "--short", "HEAD"], { stderr: "ignore" });
	const { status, err } = judge({ status: r.exitCode ?? 128, out: r.stdout.toString() });
	for (const line of err) console.error(line);
	process.exit(status);
}

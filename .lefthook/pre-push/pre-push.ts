// This is the pre-push hook. It runs scripts/no-private-refs.ts,
// scripts/outdated.ts and scripts/verified-push.ts. They run from here
// because Git's list of pushed refs, which lefthook forwards through
// `use_stdin`, decides whether any runs. no-private-refs.ts needs the pushed
// refs and tips from it, and the URL pushed to, which Git passes as the
// second argument; verified-push.ts needs the tips.
//
// lefthook runs it as a script rather than a command: lefthook skips a
// pre-push command whenever `git diff HEAD @{push}` lists no files, which is
// the case for a force-push that only rewrites history, and would let
// rewritten commit messages out unscanned.

import { join } from "node:path";

const ZERO = "0".repeat(40);

export type Plan = { skip: true; message?: string } | { skip: false; tips: string[]; scanArgs: string[] };

// What to run for Git's stdin, one line per ref: local ref and SHA, then
// remote ref and SHA. A zero local SHA means deletion. `git push origin
// --delete <branch>` runs this hook too, but pushes no commits; outdated.ts
// can otherwise block deleting a merged branch when a dependency is behind
// its latest release or a registry is unreachable. So the checks are skipped
// when every ref being pushed is a deletion, and when there are no refs at
// all, as for a push that has nothing to send.
export function plan(stdin: string, url: string): Plan {
	const lines = stdin.split("\n").filter((l) => l.trim() !== "");
	const tips: string[] = [];
	const scanArgs = ["--remote", url];
	for (const line of lines) {
		const [, localSha, remoteRef] = line.trim().split(/\s+/);
		if (localSha === ZERO) continue;
		tips.push(localSha);
		scanArgs.push("--ref", remoteRef, localSha);
	}
	if (tips.length > 0) return { skip: false, tips, scanArgs };
	return lines.length > 0 ? { skip: true, message: "pre-push: only deleting remote refs; skipping checks." } : { skip: true };
}

// Runs the checks for `p`, returning the hook's exit status. Either check
// failing blocks the push, but both always run so each can report its
// findings. verified-push.ts can run scripts/check.ts once per unchecked
// tip, which takes minutes each, so it runs only when the push would
// otherwise go through.
export function runChecks(p: Plan, run: (cmd: string[]) => number, log: (s: string) => void): number {
	if (p.skip) {
		if (p.message) log(p.message);
		return 0;
	}
	let status = 0;
	if (run(["bun", "scripts/no-private-refs.ts", ...p.scanArgs]) !== 0) status = 1;
	if (run(["bun", "scripts/outdated.ts"]) !== 0) status = 1;
	if (status === 0 && run(["bun", "scripts/verified-push.ts", ...p.tips]) !== 0) status = 1;
	return status;
}

// The hook for its arguments, the remote's name and the URL pushed to,
// which can differ from the one fetched from, and Git's stdin.
export const prePush = (args: string[], stdin: string, run: (cmd: string[]) => number, log: (s: string) => void) =>
	runChecks(plan(stdin, args[1] ?? ""), run, log);

if (import.meta.main) {
	process.chdir(join(import.meta.dir, "../.."));
	const run = (cmd: string[]) => Bun.spawnSync(cmd, { stdio: ["ignore", "inherit", "inherit"] }).exitCode ?? 1;
	process.exit(prePush(process.argv.slice(2), await Bun.stdin.text(), run, console.log));
}

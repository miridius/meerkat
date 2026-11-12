// Pre-push check: every commit pushed as a ref's new tip must have contents
// that passed scripts/check.ts and the mutation gate of scripts/mutate.ts, as
// scripts/checked-trees.ts records them. A rebase or cherry-pick makes a
// commit without running the pre-commit hook, and git runs no hook that can
// refuse a finished rebase, so without this its contents would reach CI
// unchecked and its lib lines, conflict resolutions included, unmutated.
//
// Merge commits are refused before any gate runs: branches take in main by
// rebasing. A push is refused when it brings a commit with more than one
// parent that no remote-tracking ref holds.
//
//   verified-push.ts <sha>...
//
// An unchecked tip that is HEAD, with nothing uncommitted or untracked, is
// checked now. An unchecked HEAD in a worktree holding anything else is
// refused. Any other unchecked tip, such as a branch below HEAD that
// `gh stack sync` rebased and pushes with it, is checked in a temporary
// worktree of that commit.

import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { type Env, type Git, git, holds, type Records, records, withoutGitLocals } from "./checked-trees";

export type Io = {
	git: Git;
	records: Records;
	err: (line: string) => void;
	// Runs a gate's command in `dir` (default the checkout), returning its
	// exit status.
	run: (cmd: string[], opts?: { dir?: string; env?: Env }) => Promise<number>;
	// Runs `gates` in a new detached worktree of `commit`, which builds
	// everything from scratch, then removes it, even when a gate is
	// interrupted. Returns what `gates` returned, or false when the worktree
	// could not be made.
	elsewhere: (commit: string, gates: (dir: string, env: Env) => Promise<boolean>) => Promise<boolean>;
	env: Env;
};

// Whether commit `c`'s contents passed both gates.
const gated = (r: Records, c: string) => r.has("checked", c) && r.has("mutated", c);

// Runs, on the checkout of `commit` in `dir`, each gate its contents have not
// passed: `check.ts --head`, then `mutate.ts changed` against origin/main,
// which mutates every lib line the commit changed since main. If check.ts
// fails, mutate.ts is not run.
export async function runGates(commit: string, io: Io, dir?: string, env?: Env): Promise<boolean> {
	if (!io.records.has("checked", commit) && (await io.run(["bun", "scripts/check.ts", "--head"], { dir, env })) !== 0)
		return false;
	if (!io.records.has("mutated", commit)) {
		const mutate = await io.run(["bun", "scripts/mutate.ts", "changed"], {
			dir,
			env: { ...(env ?? io.env), BASE_BRANCH: "origin/main" },
		});
		if (mutate !== 0) return false;
	}
	return true;
}

// The commits among `shas`, or the status of a push to refuse: a tag can
// point at something other than a commit, and only commits are built;
// anything git cannot read is refused rather than skipped.
export function commitsOf(shas: string[], io: Pick<Io, "git" | "err">): { commits: string[]; status: number } {
	const commits: string[] = [];
	let status = 0;
	for (const sha of shas) {
		const object = io.git(["rev-parse", "--verify", "--quiet", `${sha}^{}`]);
		const type = object.status === 0 ? io.git(["cat-file", "-t", object.out.trim()]) : object;
		if (type.status !== 0) {
			io.err(`pre-push: cannot read ${sha}.`);
			status = 1;
		} else if (type.out.trim() === "commit") commits.push(object.out.trim());
	}
	return { commits, status };
}

// Whether the push brings a merge commit, saying so. A stale remote-tracking
// ref can only make this refuse more: a merge the remote already holds is let
// through once `git fetch` has brought it.
export function bringsMerges(commits: string[], io: Pick<Io, "git" | "err">): boolean {
	const merges = io.git(["rev-list", "--min-parents=2", ...commits, "--not", "--remotes"]);
	if (merges.status !== 0) {
		io.err("pre-push: cannot list the commits being pushed.");
		return true;
	}
	const shas = merges.out.split("\n").filter((s) => s !== "");
	if (shas.length === 0) return false;
	io.err("pre-push: merge commits are refused; rebase onto main instead:");
	io.err(io.git(["log", "--no-walk", "--format=  %h %s", ...shas]).out.trimEnd());
	return true;
}

// The hook's exit status for the pushed tips `shas`.
export async function verifiedPush(shas: string[], io: Io): Promise<number> {
	let { commits, status } = commitsOf(shas, io);
	if (commits.length === 0) return status;
	if (bringsMerges(commits, io)) return 1;

	const head = io.git(["rev-parse", "HEAD"]).out.trim();
	for (const commit of commits) {
		if (gated(io.records, commit)) continue;
		const short = io.git(["rev-parse", "--short", commit]).out.trim();
		if (commit !== head) {
			io.err(`pre-push: ${short} has not passed the commit gate; checking it now in a`);
			io.err("temporary worktree.");
			if (!(await io.elsewhere(commit, (dir, env) => runGates(commit, io, dir, env)))) {
				io.err(`pre-push: ${short} failed the commit gate.`);
				status = 1;
			} else if (!gated(io.records, commit)) {
				io.err(`pre-push: ${short} passed the commit gate but was not recorded.`);
				status = 1;
			}
		} else if (!holds(io.git, commit)) {
			io.err(`pre-push: HEAD (${short}) has not passed the commit gate, and the worktree has`);
			io.err("uncommitted or untracked files, so it cannot be checked as committed.");
			io.err("Commit or remove them, then push again.");
			status = 1;
		} else {
			io.err(`pre-push: HEAD (${short}) has not passed the commit gate since it was made`);
			io.err("(a rebase or cherry-pick skips the pre-commit hook); checking it now.");
			if (!(await runGates(commit, io))) status = 1;
			else if (!gated(io.records, commit)) {
				// Neither gate records anything when the worktree changed while it ran.
				io.err(`pre-push: the worktree changed while HEAD (${short}) was being checked.`);
				io.err("Push again once it holds exactly HEAD.");
				status = 1;
			}
		}
	}
	return status;
}

const SIGNALS = ["SIGINT", "SIGHUP", "SIGTERM"] as const;

if (import.meta.main) {
	process.chdir(git(["rev-parse", "--show-toplevel"]).out.trim());

	// A Ctrl-C, a closed terminal or a kill stops the push once the command it
	// reaches has ended, and once any temporary worktree is removed: the gates
	// run as their own processes, which handle the signal themselves, as the
	// BEAM does. This process then dies of the signal, so a calling shell
	// stops too.
	let caught: (typeof SIGNALS)[number] | undefined;
	// While a temporary worktree exists, a signal ends its gates but this
	// process stops only once the worktree is removed.
	let cleanupPending = false;
	for (const s of SIGNALS)
		process.on(s, () => {
			caught ??= s;
		});
	const stopIfSignalled = async () => {
		// Lets a signal that arrived while a command ran reach its handler.
		await Bun.sleep(0);
		if (caught === undefined || cleanupPending) return;
		for (const s of SIGNALS) process.removeAllListeners(s);
		process.kill(process.pid, caught);
	};

	const run: Io["run"] = async (cmd, opts = {}) => {
		const p = Bun.spawn(cmd, { cwd: opts.dir, env: opts.env ?? process.env, stdio: ["inherit", "inherit", "inherit"] });
		const status = await p.exited;
		await stopIfSignalled();
		return caught === undefined ? status : 130;
	};

	const elsewhere: Io["elsewhere"] = async (commit, gates) => {
		const tmp = mkdtempSync(join(tmpdir(), "verified-push-"));
		const tree = join(tmp, "tree");
		let ok = false;
		cleanupPending = true;
		try {
			// No hooks: post-checkout would run lefthook, which the new worktree
			// lacks.
			const add = Bun.spawnSync(["git", "-c", "core.hooksPath=/dev/null", "worktree", "add", "-q", "--detach", tree, commit], {
				stdio: ["ignore", "inherit", "inherit"],
			});
			// Git exports GIT_DIR and friends to hooks; left set, they would
			// point the check's git commands at this checkout instead.
			const env = withoutGitLocals(process.env, git(["rev-parse", "--local-env-vars"]).out);
			ok = add.exitCode === 0 && (await gates(tree, env));
		} finally {
			// In a shell that ignores the signals, so that neither a second
			// Ctrl-C nor a group's TERM or HUP cuts the cleanup short.
			Bun.spawnSync(
				[
					"bash",
					"-c",
					'trap "" INT HUP TERM; [ ! -e "$1/tree" ] || git worktree remove --force "$1/tree"; rm -rf "$1"',
					"cleanup",
					tmp,
				],
				{ stdio: ["ignore", "inherit", "inherit"] },
			);
			cleanupPending = false;
		}
		await stopIfSignalled();
		return ok;
	};

	const status = await verifiedPush(process.argv.slice(2), {
		git,
		records: records(git),
		err: (line) => console.error(line),
		run,
		elsewhere,
		env: process.env,
	});
	process.exit(status);
}

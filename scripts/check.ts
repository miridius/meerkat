// Pre-commit gate: runs every check CI runs, in this checkout. As in CI,
// both dependency audits fail when they cannot reach their registry, and
// `pnpm install --frozen-lockfile` fails a commit whose pnpm-lock.yaml does
// not match its package.json files.
//
// `check.ts --head`, run by scripts/verified-push.sh, checks HEAD instead of
// the commit being made.
//
// In pre-commit mode, a commit that changes only Markdown files, or nothing,
// skips the checks, and one that changes no e2e input, as
// scripts/e2e-inputs.ts judges, skips the e2e steps; CI still runs them all
// on the PR. The checks that run wait for a slot through scripts/gate-run.sh,
// which runs this script's gated part, `check.ts --gated <label> <tree>
// <e2e>`, in it.
//
// When the checks pass and the worktree held exactly the contents checked,
// with no untracked file, both when they started and when they finished,
// scripts/checked-trees.ts records those contents: with --e2e when the e2e
// steps ran, and as checked when they ran or the contents' e2e inputs already
// passed them. Contents that skipped them on inputs never recorded that way
// stay unchecked, so the pre-push check runs every step on a tip that holds
// them.

import { writeSync } from "node:fs";
import { join } from "node:path";
import { type Env, type Git, git, holds, type Records, records } from "./checked-trees";
import { isInput } from "./e2e-inputs";

export type Plan = { skip: string } | { label: string; e2e: boolean };

// What to check. In pre-commit mode `changed` lists the paths the commit
// changes, as `git diff --cached --no-renames --name-only` prints them;
// --no-renames lists a renamed file's old path too, so renaming code to
// *.md still runs the checks.
export function plan(head: boolean, changed: string): Plan {
	if (head) return { label: "pre-push", e2e: true };
	const paths = changed.split("\n").filter((p) => p !== "");
	if (paths.every((p) => p.endsWith(".md")))
		return { skip: "pre-commit: no files other than Markdown changed; skipping checks." };
	return { label: "pre-commit", e2e: paths.some(isInput) };
}

export type Step = { cmd: string[]; dir?: string; env?: Env };

// The checks, in order, for a checkout at `root`.
export function steps(root: string, e2e: boolean): Step[] {
	const assets = join(root, "assets");
	return [
		{ cmd: ["mix", "deps.get"] },
		{ cmd: ["bun", "scripts/hex-audit.ts"] },
		{ cmd: ["pnpm", "audit"] },
		{ cmd: ["pnpm", "install", "--frozen-lockfile", "--ignore-scripts", "--prefer-offline"] },
		{ cmd: ["mix", "compile", "--warnings-as-errors"] },
		{ cmd: ["mix", "format", "--check-formatted"] },
		{ cmd: ["mix", "credo", "--strict"] },
		{ cmd: ["bunx", "biome", "lint", "--error-on-warnings"] },
		{ cmd: ["bash", "scripts/mix-test.sh"] },
		{ cmd: ["bun", "test"], dir: assets },
		{ cmd: ["bun", "test", "tests/e2e/lib"] },
		{ cmd: ["bun", "test", "scripts"] },
		...(e2e
			? [
					{ cmd: ["bun", "run", "build"], dir: assets, env: { MIX_BUILD_PATH: join(root, "_build/dev") } },
					{ cmd: ["bunx", "playwright", "install", "--only-shell", "chromium"] },
					{ cmd: ["bun", "run", "test:e2e"] },
				]
			: []),
	];
}

// Git exports GIT_INDEX_FILE and friends to hooks; left set, they would
// point every test's fixture repo at this checkout's index.
export function withoutGitLocals(env: Env, locals: string): Env {
	const drop = new Set(locals.split("\n").filter((v) => v !== ""));
	return Object.fromEntries(Object.entries(env).filter(([k]) => !drop.has(k)));
}

export type Run = (step: Step, env: Env) => number;
export type Log = (line: string) => void;

// Which records the gated part makes once every step has passed, given
// whether the worktree held the tree before and after the steps and, when
// the e2e steps were skipped, whether the tree's e2e inputs were recorded.
export function toRecord(e2e: boolean, clean: boolean, e2eRecorded: () => boolean): ("e2e" | "checked")[] | "unproven" {
	if (!clean) return [];
	if (e2e) return ["e2e", "checked"];
	return e2eRecorded() ? ["checked"] : "unproven";
}

// The gated part, run in a gate slot: the checks, then the records. Returns
// the exit status.
export function gated(
	label: string,
	tree: string,
	e2e: boolean,
	io: { git: Git; records: Records; root: string; env: Env; run: Run; log: Log },
): number {
	const before = holds(io.git, tree);
	const env = withoutGitLocals(io.env, io.git(["rev-parse", "--local-env-vars"]).out);
	for (const step of steps(io.root, e2e)) {
		io.log("");
		io.log(`=== ${label}: ${step.cmd.join(" ")} ===`);
		if (io.run(step, { ...env, ...step.env }) !== 0) return 1;
	}
	if (!e2e) {
		io.log("");
		io.log(`=== ${label}: no e2e input changed; skipping the build and e2e steps ===`);
	}

	// Checked again in case the worktree changed while the checks ran.
	const r = toRecord(e2e, before && holds(io.git, tree, env), () => io.records.has("e2e", tree));
	if (r === "unproven") {
		io.log("");
		io.log(`${label}: these contents' e2e inputs never passed the e2e steps here;`);
		io.log("the pre-push check will run every check on a pushed tip that holds them.");
	} else {
		for (const store of r) if (!io.records.mark(store, tree)) return 1;
	}

	io.log("");
	io.log(`=== ${label}: all checks passed ===`);
	return 0;
}

// The ungated part: decides what to check, then runs the gated part in a
// gate slot. Returns the exit status.
export function check(
	args: string[],
	io: { git: Git; log: Log; gate: (label: string, tree: string, e2e: boolean) => number },
): number {
	const head = args[0] === "--head";
	// During `git commit -a` or `git commit <paths>`, GIT_INDEX_FILE names a
	// temporary index holding the commit's contents, so it is read before
	// the gated part clears git's environment. HEAD is resolved now, as it can
	// move while the checks run.
	let changed = "";
	if (!head) {
		const diff = io.git(["diff", "--cached", "--no-renames", "--name-only"]);
		if (diff.status !== 0) return 1;
		changed = diff.out;
	}
	const p = plan(head, changed);
	if ("skip" in p) {
		io.log(p.skip);
		return 0;
	}
	const tree = io.git(head ? ["rev-parse", "--verify", "HEAD^{tree}"] : ["write-tree"]);
	if (tree.status !== 0) return 1;
	return io.gate(p.label, tree.out.trim(), p.e2e);
}

const log: Log = (line) => writeSync(1, `${line}\n`);

if (import.meta.main) {
	const root = git(["rev-parse", "--show-toplevel"]).out.trim();
	process.chdir(root);
	const args = process.argv.slice(2);
	if (args[0] === "--gated") {
		const run: Run = (step, env) =>
			Bun.spawnSync(step.cmd, { cwd: step.dir ?? root, env, stdio: ["inherit", "inherit", "inherit"] }).exitCode ?? 1;
		const [, label, tree, e2e] = args;
		process.exit(gated(label, tree, e2e === "1", { git, records: records(git), root, env: process.env, run, log }));
	}
	const gate = (label: string, tree: string, e2e: boolean) =>
		Bun.spawnSync(["bash", "scripts/gate-run.sh", "bun", "scripts/check.ts", "--gated", label, tree, e2e ? "1" : "0"], {
			stdio: ["inherit", "inherit", "inherit"],
		}).exitCode ?? 1;
	process.exit(check(args, { git, log, gate }));
}

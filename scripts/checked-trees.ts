// Records which commit contents have passed scripts/check.ts, or with
// --mutated the mutation gate of scripts/mutate.ts, so the pre-push hook can
// tell whether a commit it is about to push was ever checked. A rebase or
// cherry-pick makes commits without running the pre-commit hook. With --e2e
// it records which contents passed check.ts's e2e steps, so a commit that
// skips them can count as checked when its e2e inputs already passed.
//
//   checked-trees.ts [--mutated|--e2e] mark <tree-ish>  record that its
//                                                       contents passed
//   checked-trees.ts [--mutated|--e2e] has <tree-ish>   exit 0 if its contents
//                                                       passed, else 1
//   checked-trees.ts holds <tree-ish>  exit 0 if the worktree holds exactly its
//                                      contents, with no untracked file, else 1
//
// Contents are keyed on every file except Markdown, which neither gate tests:
// a commit that changes only Markdown counts as checked when its parent was.
// The --e2e record is keyed on the e2e inputs scripts/e2e-inputs.ts picks.
// Marks live in the git common dir, so every worktree shares them.

import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { isInput } from "./e2e-inputs";

export type Env = Record<string, string | undefined>;
export type GitResult = { status: number; out: string };
// Runs git with `args`, feeding it `input`, in `env` (default this process's).
export type Git = (args: string[], opts?: { input?: string; env?: Env }) => GitResult;

export const git: Git = (args, opts = {}) => {
	const r = Bun.spawnSync(["git", ...args], {
		stdin: opts.input === undefined ? "ignore" : Buffer.from(opts.input),
		stdout: "pipe",
		stderr: "inherit",
		env: opts.env ?? process.env,
	});
	return { status: r.exitCode ?? 1, out: r.stdout.toString() };
};

// `env` without the variables `git rev-parse --local-env-vars` lists as
// `locals`. Git exports GIT_INDEX_FILE and friends to hooks; left set, they
// would point a command run for another checkout, or a test's fixture repo,
// at this checkout.
export function withoutGitLocals(env: Env, locals: string): Env {
	const drop = new Set(locals.split("\n").filter((v) => v !== ""));
	return Object.fromEntries(Object.entries(env).filter(([k]) => !drop.has(k)));
}

export type Store = "checked" | "mutated" | "e2e";

const DIRS: Record<Store, string> = { checked: "meerkat-checked", mutated: "meerkat-mutated", e2e: "meerkat-e2e" };

// The lines of a `git ls-tree -r` listing that a store's key covers.
export function keyed(store: Store, listing: string): string {
	const keep = store === "e2e" ? isInput : (line: string) => !/\t.*\.md$/.test(line);
	return listing
		.split("\n")
		.filter((line) => line !== "" && keep(line))
		.map((line) => `${line}\n`)
		.join("");
}

// The key of `rev`'s contents in `store`, or null when git cannot list them.
export function key(g: Git, store: Store, rev: string): string | null {
	const listing = g(["ls-tree", "-r", "--full-tree", `${rev}^{tree}`]);
	if (listing.status !== 0) return null;
	const hash = g(["hash-object", "--stdin"], { input: keyed(store, listing.out) });
	return hash.status === 0 ? hash.out.trim() : null;
}

// Where `store`'s marks live, or null when git cannot say.
export function storeDir(g: Git, store: Store): string | null {
	const common = g(["rev-parse", "--path-format=absolute", "--git-common-dir"]);
	return common.status === 0 ? join(common.out.trim(), DIRS[store]) : null;
}

// The marks of one store: a file named for each key that passed.
export type Marks = { has(key: string): boolean; mark(key: string): void };

export const fileMarks = (dir: string): Marks => ({
	has: (k) => existsSync(join(dir, k)),
	mark: (k) => {
		mkdirSync(dir, { recursive: true });
		writeFileSync(join(dir, k), "");
	},
});

export type Records = { has(store: Store, rev: string): boolean; mark(store: Store, rev: string): boolean };

// The records in the repository `g` runs in. A mark fails, and a lookup
// finds nothing, when git cannot key the contents or find the store.
export function records(g: Git, marks: (dir: string) => Marks = fileMarks): Records {
	const at = (store: Store, rev: string) => {
		const k = key(g, store, rev);
		const dir = k === null ? null : storeDir(g, store);
		return k === null || dir === null ? null : { k, m: marks(dir) };
	};
	return {
		has(store, rev) {
			const a = at(store, rev);
			return a?.m.has(a.k) === true;
		},
		mark(store, rev) {
			const a = at(store, rev);
			if (a === null) return false;
			a.m.mark(a.k);
			return true;
		},
	};
}

// Whether the worktree holds exactly `rev`'s contents, with no untracked
// file. Unlike `git status`, neither command hides untracked files under
// status.showUntrackedFiles=no, and a git error counts as not holding.
export function holds(g: Git, rev: string, env?: Env): boolean {
	if (g(["diff", "--quiet", `${rev}^{tree}`, "--"], { env }).status !== 0) return false;
	const others = g(["ls-files", "--others", "--exclude-standard"], { env });
	return others.status === 0 && others.out === "";
}

const USAGE = "usage: checked-trees.ts [--mutated|--e2e] mark|has|holds <tree-ish>";

// The CLI's exit status for `args`.
export function main(args: string[], g: Git, r: Records = records(g)): number {
	let store: Store = "checked";
	if (args[0] === "--mutated" || args[0] === "--e2e") {
		store = args[0] === "--mutated" ? "mutated" : "e2e";
		args = args.slice(1);
	}
	if (args.length !== 2) return usage();
	const [cmd, rev] = args;
	if (cmd === "mark") return r.mark(store, rev) ? 0 : 1;
	if (cmd === "has") return r.has(store, rev) ? 0 : 1;
	if (cmd === "holds") return holds(g, rev) ? 0 : 1;
	return usage();
}

function usage(): number {
	console.error(USAGE);
	return 2;
}

if (import.meta.main) process.exit(main(process.argv.slice(2), git));

// Mutation testing for meerkat.
//
// Runs `mix muex` against the meerkat Elixir code. muex rewrites operators /
// literals one at a time and re-runs the tests that cover each rewrite. A
// rewrite those tests still pass against is an uncovered behaviour — fix the
// test or the code.
//
// Modes:
//   scripts/mutate.ts             — mutate every line of every
//                                   lib/meerkat/*.ex (skips application —
//                                   supervisor plumbing). Slow.
//   scripts/mutate.ts changed     — mutate only the lib/**/*.ex lines changed
//                                   vs the merge base with origin/main
//                                   (override with BASE_BRANCH), uncommitted
//                                   edits included (muex --since). The
//                                   pre-push hook runs this mode on a pushed
//                                   tip with no mutation record.
//   scripts/mutate.ts staged      — mutate only the lib/**/*.ex lines staged
//                                   for the next commit (muex --staged). The
//                                   lefthook pre-commit hook runs this mode.
//   scripts/mutate.ts <path…>     — mutate every line of the named
//                                   lib/**/*.ex files, refusing any other
//                                   path.
//
// Every mode fails when any mutant survives, no test reaches it, or its tests
// time out.
//
// A pass of either gated mode records the contents it judged with
// scripts/checked-trees.ts --mutated when they are known to be gated
// throughout: see `plan`. Those modes run muex in a gate slot, through
// scripts/gate-run.sh, which runs this script's gated part,
// `mutate.ts --gated <run as JSON>`, in it.
//
// Pass extra muex flags through after `--`:
//   scripts/mutate.ts changed -- --concurrency 4

import { mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeSync } from "node:fs";
import { availableParallelism } from "node:os";
import { join } from "node:path";
import { type Env, type Git, git, holds, type Records, records, withoutGitLocals } from "./checked-trees";

const NAME = "scripts/mutate.ts";

// Files muex's operator rewrites would just churn through without real
// signal. Supervisor plumbing.
const SKIP = new Set(["lib/meerkat/application.ex"]);

// What the gated part runs, decided before it.
export type Run = {
	mode: string;
	label: string;
	files: string[];
	// muex's flags that pick the lines: none, --since or --staged.
	scope: string[];
	// The index muex --since or --staged reads, as GIT_INDEX_FILE, after the
	// rest of git's hook environment is cleared.
	index?: string;
	extra: string[];
	// The contents judged, and whether a pass records them: the worktree must
	// still hold them afterwards, since muex tests the files on disk.
	tree: string;
	record: boolean;
};

// An early end: the exit status, and what to print to stdout or stderr.
export type Done = { exit: number; out?: string[]; err?: string[] };

export type Io = {
	git: Git;
	records: Records;
	env: Env;
	// The repo's files under `dir` named like `*.ex`, to `depth` if given,
	// sorted.
	find: (dir: string, suffix: string, depth?: number) => string[];
	isFile: (path: string) => boolean;
	isDir: (path: string) => boolean;
	cwd: string;
};

// Splits the arguments into the mode, its paths and the flags for muex.
// `mutate.ts -- <muex flags>` is the default mode with flags. In the paths
// mode, every argument up to `--` is a path, and a flag-shaped one is almost
// always a forgotten `--`, so it is refused rather than passed to muex as a
// bogus path. In the other modes, every argument but `--` itself goes to
// muex.
export function parse(args: string[]): { mode: string; paths: string[]; extra: string[] } | Done {
	const [first = "default", ...rest] = args;
	if (first === "--") return { mode: "default", paths: [], extra: rest };
	if (first === "default" || first === "changed" || first === "staged") {
		const i = rest.indexOf("--");
		return { mode: first, paths: [], extra: i < 0 ? rest : [...rest.slice(0, i), ...rest.slice(i + 1)] };
	}
	if (first.startsWith("-"))
		return {
			exit: 2,
			err: [`${NAME}: '${first}' looks like a flag. Did you forget '--'?`, `Usage: ${NAME} <path…> [-- <muex flags>]`],
		};
	const end = rest.indexOf("--");
	const paths = [first, ...(end < 0 ? rest : rest.slice(0, end))];
	const flag = paths.find((p) => p.startsWith("-"));
	if (flag !== undefined) return { exit: 2, err: [`${NAME}: '${flag}' looks like a flag. Did you forget '--'?`] };
	return { mode: "paths", paths, extra: end < 0 ? [] : rest.slice(end + 1) };
}

// The paths given to the paths mode that are not an existing lib/**/*.ex
// file named relative to the repo root. muex skips such a path without a
// word, so the run would pass without judging it.
export const badPaths = (paths: string[], isFile: (path: string) => boolean) =>
	paths.filter((p) => !/^lib\/.*\.ex$/.test(p) || !isFile(p));

// Whether a `git diff --unified=0` adds or changes a line, the only lines
// muex's --since / --staged can mutate.
export const addsLines = (diff: string) => diff.split("\n").some((l) => l.startsWith("+") && !l.startsWith("+++ "));

// Whether `git diff <args>` adds or changes any lib/**/*.ex line, or null
// when git fails. An external diff tool or textconv filter would print no
// `+` lines and skip the gate.
function libLinesAdded(g: Git, args: string[]): boolean | null {
	const diff = g([
		"diff",
		"--no-ext-diff",
		"--no-textconv",
		"--unified=0",
		"--no-color",
		"--diff-filter=d",
		...args,
		"--",
		":(glob)lib/**/*.ex",
	]);
	return diff.status === 0 ? addsLines(diff.out) : null;
}

const gitPathIndex = (g: Git) => g(["rev-parse", "--path-format=absolute", "--git-path", "index"]).out.trim();

// Decides what to mutate, and whether a pass records it, before any gate
// slot is taken: a run that ends here returns its Done.
export function plan(args: string[], io: Io): Run | Done {
	if (!io.isDir("lib/meerkat"))
		return { exit: 2, err: [`${NAME}: lib/meerkat not found at ${io.cwd} — run from the meerkat repo.`] };
	const p = parse(args);
	if ("exit" in p) return p;
	let files: string[] = [];
	let scope: string[] = [];
	let index: string | undefined;
	let tree = "";
	let record = false;
	let label = "selected";
	// A gated mode with nothing to mutate still records its contents.
	const nothing = (msg: string): Done => {
		if (record && holds(io.git, tree) && !io.records.mark("mutated", tree)) return { exit: 1 };
		return { exit: 0, out: [msg] };
	};

	const libFiles = () => io.find("lib", ".ex").filter((f) => !SKIP.has(f));
	switch (p.mode) {
		case "default":
			files = io.find("lib/meerkat", ".ex", 1).filter((f) => !SKIP.has(f));
			break;
		case "changed": {
			const base = io.env.BASE_BRANCH || "origin/main";
			if (io.git(["rev-parse", "--verify", base]).status !== 0)
				return { exit: 2, err: [`${NAME}: base ref '${base}' not found; fetch origin first.`] };
			index = gitPathIndex(io.git);
			// A run against origin/main on exactly HEAD judges every lib line
			// HEAD changed since main.
			const head = io.git(["rev-parse", "--verify", "--quiet", "HEAD^{tree}"]);
			if (base === "origin/main" && head.status === 0) {
				tree = head.out.trim();
				record = holds(io.git, tree);
			}
			const added = libLinesAdded(io.git, ["--merge-base", base]);
			if (added === null) return { exit: 2, err: [`${NAME}: git diff --merge-base ${base} failed.`] };
			if (!added) return nothing(`${NAME}: no lib/**/*.ex lines changed vs ${base} — nothing to mutate.`);
			files = libFiles();
			scope = ["--since", base];
			label = "changed";
			break;
		}
		case "staged": {
			// During `git commit -a` or `git commit <paths>`, GIT_INDEX_FILE
			// names a temporary index holding the commit's contents. --git-path
			// resolves it (or the usual index) to an absolute path.
			index = gitPathIndex(io.git);
			tree = io.git(["write-tree"]).out.trim();
			// The commit's other lib lines come from HEAD, so its contents are
			// gated throughout only when HEAD's were, or HEAD is in origin/main.
			// A root commit stages every line.
			record =
				holds(io.git, tree) &&
				(io.git(["rev-parse", "--verify", "--quiet", "HEAD"]).status !== 0 ||
					io.records.has("mutated", "HEAD") ||
					io.git(["merge-base", "--is-ancestor", "HEAD", "origin/main"]).status === 0);
			const added = libLinesAdded(io.git, ["--cached"]);
			if (added === null) return { exit: 2, err: [`${NAME}: git diff --cached failed.`] };
			if (!added) return nothing(`${NAME}: no lib/**/*.ex lines staged — nothing to mutate.`);
			files = libFiles();
			scope = ["--staged"];
			label = "staged";
			break;
		}
		default: {
			const bad = badPaths(p.paths, io.isFile);
			if (bad.length > 0) return { exit: 2, err: bad.map((b) => `${NAME}: ${b} is not a lib/**/*.ex file.`) };
			files = p.paths;
		}
	}
	if (files.length === 0) return { exit: 2, err: [`${NAME}: no files selected — nothing to mutate.`] };
	// A flag such as --max-mutations can narrow the run, so it records nothing.
	if (p.extra.length > 0) record = false;
	return { mode: p.mode, label, files, scope, index, extra: p.extra, tree, record };
}

// What the run prints before it starts.
export const announce = (run: Run) =>
	run.scope.length === 0
		? [`${NAME}: mutating ${run.files.length} file(s):`, ...run.files.map((f) => `  ${f}`)]
		: [`${NAME}: mutating the ${run.mode} lines of lib/**/*.ex.`];

export type Mutation = {
	status: string;
	description: string;
	location: { file: string; line: number };
	patch?: { before: string; after: string } | null;
};

// Only these statuses are judged; one muex adds later would otherwise pass
// unseen.
const KNOWN = ["killed", "survived", "no_coverage", "timeout", "invalid", "equivalent", "ignored"];

export const unknownStatuses = (ms: Mutation[]) =>
	[...new Set(ms.map((m) => m.status).filter((s) => !KNOWN.includes(s)))].sort();

// One entry per mutant with one of `statuses`. muex's patch holds the whole
// enclosing expression, which for a deleted statement is the whole module
// body, so only the lines one side has and the other lacks are shown, at most
// six per side.
export function listMutants(ms: Mutation[], statuses: string[]): string[] {
	const only = (sign: string, lines: string[], other: string[]) => {
		const diff = lines.filter((l) => !other.includes(l));
		const shown = diff.slice(0, 6).map((l) => `\n    ${sign} ${l}`);
		return shown.join("") + (diff.length > 6 ? `\n    ${sign} …` : "");
	};
	return ms
		.filter((m) => statuses.includes(m.status))
		.map((m) => {
			const head = `${m.location.file}:${m.location.line}  ${m.status}  ${m.description}`;
			if (!m.patch) return head;
			const b = m.patch.before.split("\n");
			const a = m.patch.after.split("\n");
			return head + only("-", b, a) + only("+", a, b);
		});
}

// Judges muex's report rather than its score: muex's default --fail-at
// passes a run with survivors, its score ignores no-coverage mutants, and
// lines that yield no mutants have nothing to score, and must pass. A
// survivor is a judged line whose behaviour the tests do not pin down. A
// no-coverage mutant is the same gap, found without running: no ExUnit test
// executes its line. A timed-out mutant was judged by no test at all: see
// the --timeout in `muexArgs`.
export function judge(ms: Mutation[], run: Pick<Run, "label" | "mode">): Done {
	const unknown = unknownStatuses(ms);
	if (unknown.length > 0)
		return { exit: 2, err: [`${NAME}: muex reported unknown mutant status(es): ${unknown.join(", ")}.`] };
	const failing = listMutants(ms, ["survived", "no_coverage"]);
	const timedOut = listMutants(ms, ["timeout"]);
	const out: string[] = [];
	if (failing.length > 0)
		out.push(
			"",
			`${NAME}: ${run.label} lib/ lines have untested behaviour:`,
			"",
			...failing,
			"",
			`Add or tighten a test that fails for each mutant above, in this ${run.mode === "staged" ? "commit" : "branch"}.`,
			'See CLAUDE.md "Mutation testing" for the documented exceptions.',
		);
	if (timedOut.length > 0)
		out.push(
			"",
			`${NAME}: no test judged these mutants of the ${run.label} lib/ lines; their runs passed muex's time limits:`,
			"",
			...timedOut,
			"",
			"Rerun once the machine is less loaded.",
		);
	return { exit: out.length > 0 ? 1 : 0, out };
}

// The `mix muex` command for `run`, given its test files and how many test
// BEAMs to run at once, writing its JSON report to `report`.
//
// --coverage-guided runs each mutant against the test files that execute its
// line, and skips mutants on lines no test executes (reported as no
// coverage). For lines `:cover` has no data for, it falls back to muex's
// dependency analysis, then to every test file it is given. Every selected
// line counts, so --no-filter keeps muex from skipping a file it rates too
// simple to be worth mutating, and --no-optimize from dropping the mutants
// of a function it rates too simple. muex gives up on a mutant's `mix test`
// once ExUnit has run its tests for --timeout ms, counted from the suite's
// start; booting and compiling get the larger of 60 s and six times
// --timeout. A line every test executes runs every test file in one BEAM,
// which took 129 s in one run. Keep --timeout well above that plus ExUnit's
// per-test timeout (test/test_helper.exs), so under load a hang inside a
// test still fails first, which is a kill. A --concurrency among the extra
// flags overrides `jobs`.
export function muexArgs(run: Run, tests: string[], jobs: number, report: string): string[] {
	return [
		"mix",
		"muex",
		"--files",
		run.files.join(","),
		"--test-paths",
		tests.join(","),
		"--coverage-guided",
		"--concurrency",
		String(jobs),
		"--no-filter",
		"--no-optimize",
		"--timeout",
		"900000",
		...run.scope,
		"--fail-at",
		"0",
		"--format",
		"json",
		"--output",
		report,
		...run.extra,
	];
}

// muex runs as many test BEAMs at once as there are cores; like
// scripts/mix-test.sh, cap them at half (at least one) so a commit leaves the
// machine usable.
export const jobsFor = (cores: number) => Math.max(1, Math.floor(cores / 2));

// To find which tests execute which lines, muex first runs every test file
// it is given under :cover, whatever lines are mutated. The files under
// test/scripts drive shell scripts in subprocesses, so in their own BEAM they
// execute only the app-start lines every test file executes; leaving them out
// cuts that run by over half without changing which mutants are killed.
export const testPaths = (all: string[]) => all.filter((f) => !f.startsWith("test/scripts/"));

export type GatedIo = {
	git: Git;
	records: Records;
	env: Env;
	root: string;
	cores: number;
	find: Io["find"];
	run: (cmd: string[], env: Env) => number;
	// The report's mutations, or null when muex wrote none.
	readReport: (path: string) => Mutation[] | null;
	removeReport: (path: string) => void;
	log: (line: string) => void;
	err: (line: string) => void;
};

// The muex run and its judgement, in a gate slot for the gated modes.
// Returns the exit status.
export function gated(run: Run, io: GatedIo): number {
	// Git exports GIT_DIR, GIT_INDEX_FILE and friends to hooks; left set, they
	// would point Mix's checkout of git dependencies, and every test's fixture
	// repo, at this repository.
	const env = withoutGitLocals(io.env, io.git(["rev-parse", "--local-env-vars"]).out);
	// The suite needs node_modules, which a fresh worktree lacks.
	for (const [cmd, extra] of [
		[["mix", "deps.get"], { MIX_ENV: "test" }],
		[["pnpm", "install", "--frozen-lockfile", "--ignore-scripts", "--prefer-offline"], {}],
		[["mix", "compile", "--warnings-as-errors"], { MIX_ENV: "test" }],
	] as const) {
		const status = io.run([...cmd], { ...env, ...extra });
		if (status !== 0) return status;
	}

	// muex prints the report's path, so the report is kept, in _build/, until
	// the next run replaces it. muex writes no report when there is nothing to
	// mutate, as for staged comments or lib/meerkat/application.ex alone, so
	// an earlier run's report must not be left for this run to judge.
	const report = join(io.root, "_build", `mutate-${run.label}.json`);
	io.removeReport(report);
	const tests = testPaths(io.find("test", "_test.exs"));
	// muex strips GIT_INDEX_FILE from the test runs it starts.
	const muexEnv = run.index === undefined ? env : { ...env, GIT_INDEX_FILE: run.index };
	const status = io.run(muexArgs(run, tests, jobsFor(io.cores), report), muexEnv);
	if (status !== 0) return status;

	const record = () => !run.record || !holds(io.git, run.tree, env) || io.records.mark("mutated", run.tree);
	const mutations = io.readReport(report);
	if (mutations === null) {
		io.log(`${NAME}: the ${run.label} lib/ lines produce no mutants.`);
		return record() ? 0 : 1;
	}
	const verdict = judge(mutations, run);
	for (const line of verdict.out ?? []) io.log(line);
	for (const line of verdict.err ?? []) io.err(line);
	if (verdict.exit !== 0) return verdict.exit;
	if (!record()) return 1;
	io.log(`${NAME}: no mutant of the ${run.label} lib/ lines survived.`);
	return 0;
}

// The repo's files under `dir` whose names end in `suffix`, to `depth`
// levels if given, sorted as `sort` sorts their paths.
export function find(root: string, dir: string, suffix: string, depth = Number.POSITIVE_INFINITY): string[] {
	const found: string[] = [];
	const walk = (rel: string, level: number) => {
		for (const e of readdirSync(join(root, rel), { withFileTypes: true })) {
			const path = `${rel}/${e.name}`;
			if (e.isDirectory() && level < depth) walk(path, level + 1);
			else if (e.isFile() && e.name.endsWith(suffix)) found.push(path);
		}
	};
	walk(dir, 1);
	return found.sort();
}

if (import.meta.main) {
	const root = join(import.meta.dir, "..");
	process.chdir(root);
	const out = (line: string) => writeSync(1, `${line}\n`);
	const err = (line: string) => writeSync(2, `${line}\n`);
	const done = (d: Done) => {
		for (const line of d.out ?? []) out(line);
		for (const line of d.err ?? []) err(line);
		process.exit(d.exit);
	};
	const statOf = (path: string) => statSync(path, { throwIfNoEntry: false });
	const gatedIo: GatedIo = {
		git,
		records: records(git),
		env: process.env,
		root,
		cores: availableParallelism(),
		find: (dir, suffix, depth) => find(root, dir, suffix, depth),
		run: (cmd, env) => Bun.spawnSync(cmd, { env, stdio: ["inherit", "inherit", "inherit"] }).exitCode ?? 1,
		readReport: (path) => (statOf(path)?.isFile() ? JSON.parse(readFileSync(path, "utf8")).mutations : null),
		removeReport: (path) => {
			mkdirSync(join(root, "_build"), { recursive: true });
			rmSync(path, { force: true });
		},
		log: out,
		err,
	};
	const args = process.argv.slice(2);
	if (args[0] === "--gated") process.exit(gated(JSON.parse(args[1]), gatedIo));

	const p = plan(args, {
		git,
		records: gatedIo.records,
		env: process.env,
		find: gatedIo.find,
		isFile: (path) => statOf(path)?.isFile() === true,
		isDir: (path) => statOf(path)?.isDirectory() === true,
		cwd: root,
	});
	if ("exit" in p) done(p);
	else {
		for (const line of announce(p)) out(line);
		if (p.scope.length === 0) process.exit(gated(p, gatedIo));
		const r = Bun.spawnSync(["bash", "scripts/gate-run.sh", "bun", "scripts/mutate.ts", "--gated", JSON.stringify(p)], {
			stdio: ["inherit", "inherit", "inherit"],
		});
		process.exit(r.exitCode ?? 1);
	}
}

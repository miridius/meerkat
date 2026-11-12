import { describe, expect, test } from "bun:test";
import type { Records, Store } from "./checked-trees";
import { fakeGit } from "./fake-git";
import {
	addsLines,
	announce,
	badPaths,
	type GatedIo,
	gated,
	type Io,
	judge,
	jobsFor,
	listMutants,
	type Mutation,
	muexArgs,
	parse,
	plan,
	type Run,
	testPaths,
} from "./mutate";

const LIB = ["lib/meerkat/application.ex", "lib/meerkat/one.ex", "lib/meerkat/two.ex", "lib/meerkat_web/view.ex"];

// A mutant in the shape of muex's JSON report.
const mutant = (status: string, line = 2): Mutation => ({
	status,
	description: "Comparison: == to !=",
	location: { file: "lib/meerkat/one.ex", line },
	patch: { before: "a == b", after: "a != b" },
});

const memoryRecords = (has: string[] = []) => {
	const marked: string[] = [];
	const r: Records = {
		has: (s: Store, rev) => has.includes(`${s} ${rev}`),
		mark: (s: Store, rev) => {
			marked.push(`${s} ${rev}`);
			return true;
		},
	};
	return { r, marked };
};

describe("parse", () => {
	test("reads the mode, defaulting to every file", () => {
		expect(parse([])).toEqual({ mode: "default", paths: [], extra: [] });
		expect(parse(["staged"])).toEqual({ mode: "staged", paths: [], extra: [] });
		expect(parse(["--", "--max-mutations", "1"])).toEqual({ mode: "default", paths: [], extra: ["--max-mutations", "1"] });
	});

	test("passes every other argument of a named mode to muex", () => {
		expect(parse(["changed", "--", "--concurrency", "4"])).toEqual({ mode: "changed", paths: [], extra: ["--concurrency", "4"] });
		expect(parse(["changed", "-x", "--", "y"])).toEqual({ mode: "changed", paths: [], extra: ["-x", "y"] });
	});

	test("reads paths up to `--`", () => {
		expect(parse(["lib/a.ex", "lib/b.ex", "--", "--max-mutations", "1"])).toEqual({
			mode: "paths",
			paths: ["lib/a.ex", "lib/b.ex"],
			extra: ["--max-mutations", "1"],
		});
	});

	test("refuses a flag where a path belongs, as a forgotten `--`", () => {
		expect(parse(["--max-mutations"])).toMatchObject({ exit: 2, err: ["scripts/mutate.ts: '--max-mutations' looks like a flag. Did you forget '--'?", expect.any(String)] });
		expect(parse(["lib/a.ex", "-n"])).toEqual({ exit: 2, err: ["scripts/mutate.ts: '-n' looks like a flag. Did you forget '--'?"] });
	});
});

test("badPaths refuses all but existing lib/**/*.ex files named from the repo root", () => {
	const exists = new Set(["lib/meerkat/one.ex", "code.txt", "lib/meerkat"]);
	const isFile = (p: string) => exists.has(p) && p !== "lib/meerkat";
	expect(badPaths(["lib/meerkat/one.ex", "lib/meerkat/gti.ex", "code.txt", "./lib/meerkat/one.ex"], isFile)).toEqual([
		"lib/meerkat/gti.ex",
		"code.txt",
		"./lib/meerkat/one.ex",
	]);
});

describe("addsLines", () => {
	test("counts an added or changed line, not a file header", () => {
		expect(addsLines("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -2 +2 @@\n-old\n+new\n")).toBe(true);
	});

	test("finds nothing in a diff that only deletes", () => {
		expect(addsLines("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -2 +1,0 @@\n-old\n")).toBe(false);
		expect(addsLines("")).toBe(false);
	});
});

describe("plan", () => {
	const DIFF = ":(glob)lib/**/*.ex";
	const diffArgs = (...args: string[]) =>
		["diff", "--no-ext-diff", "--no-textconv", "--unified=0", "--no-color", "--diff-filter=d", ...args, "--", DIFF].join(" ");
	const ADDED = "+++ b/lib/meerkat/one.ex\n+changed\n";
	const DELETED = "+++ b/lib/meerkat/one.ex\n-gone\n";
	const CLEAN = { "diff --quiet t1^{tree} --": "", "ls-files --others --exclude-standard": "" };

	const run = (args: string[], answers: Parameters<typeof fakeGit>[0], { env = {}, has = [] as string[], dir = true } = {}) => {
		const { g, ran } = fakeGit({ "rev-parse --path-format=absolute --git-path index": "/r/.git/index\n", ...answers });
		const { r, marked } = memoryRecords(has);
		const io: Io = {
			git: g,
			records: r,
			env,
			find: (d, _s, depth) => (d === "lib" ? LIB : LIB.filter((f) => depth === 1 && f.startsWith(`${d}/`))),
			isFile: (p) => LIB.includes(p),
			isDir: () => dir,
			cwd: "/r",
		};
		return { result: plan(args, io), marked, ran: ran.map((x) => x.args) };
	};

	test("refuses to run outside the meerkat repo", () => {
		expect(run([], {}, { dir: false }).result).toEqual({
			exit: 2,
			err: ["scripts/mutate.ts: lib/meerkat not found at /r — run from the meerkat repo."],
		});
	});

	test("mutates every lib/meerkat file but the supervisor plumbing by default, recording nothing", () => {
		expect(run([], {}).result).toEqual({
			mode: "default",
			label: "selected",
			files: ["lib/meerkat/one.ex", "lib/meerkat/two.ex"],
			scope: [],
			index: undefined,
			extra: [],
			tree: "",
			record: false,
		});
	});

	test("mutates the paths named", () => {
		expect(run(["lib/meerkat/one.ex", "lib/meerkat/two.ex"], {}).result).toMatchObject({
			mode: "paths",
			files: ["lib/meerkat/one.ex", "lib/meerkat/two.ex"],
			record: false,
		});
		expect(run(["lib/meerkat/gti.ex", "code.txt"], {}).result).toEqual({
			exit: 2,
			err: ["scripts/mutate.ts: lib/meerkat/gti.ex is not a lib/**/*.ex file.", "scripts/mutate.ts: code.txt is not a lib/**/*.ex file."],
		});
	});

	describe("changed", () => {
		const HEAD = {
			"rev-parse --verify origin/main": "abc\n",
			"rev-parse --verify --quiet HEAD^{tree}": "t1\n",
			...CLEAN,
		};

		test("mutates the lines changed since origin/main, through the index, and will record HEAD", () => {
			const r = run(["changed"], { ...HEAD, [diffArgs("--merge-base", "origin/main")]: ADDED });
			expect(r.result).toEqual({
				mode: "changed",
				label: "changed",
				files: ["lib/meerkat/one.ex", "lib/meerkat/two.ex", "lib/meerkat_web/view.ex"],
				scope: ["--since", "origin/main"],
				index: "/r/.git/index",
				extra: [],
				tree: "t1",
				record: true,
			});
		});

		test("will record nothing against another base, with uncommitted edits, or with muex flags", () => {
			const other = { ...HEAD, "rev-parse --verify main": "abc\n", [diffArgs("--merge-base", "main")]: ADDED };
			expect(run(["changed"], other, { env: { BASE_BRANCH: "main" } }).result).toMatchObject({ scope: ["--since", "main"], record: false });
			const edited = { ...HEAD, "ls-files --others --exclude-standard": "", "diff --quiet t1^{tree} --": { status: 1, out: "" }, [diffArgs("--merge-base", "origin/main")]: ADDED };
			expect(run(["changed"], edited).result).toMatchObject({ record: false });
			const flags = { ...HEAD, [diffArgs("--merge-base", "origin/main")]: ADDED };
			expect(run(["changed", "--", "--max-mutations", "1"], flags).result).toMatchObject({ extra: ["--max-mutations", "1"], record: false });
		});

		test("with no lib line changed, records HEAD and passes", () => {
			const r = run(["changed"], { ...HEAD, [diffArgs("--merge-base", "origin/main")]: DELETED });
			expect(r.result).toEqual({ exit: 0, out: ["scripts/mutate.ts: no lib/**/*.ex lines changed vs origin/main — nothing to mutate."] });
			expect(r.marked).toEqual(["mutated t1"]);
		});

		test("refuses a base that does not exist, or a diff git cannot make", () => {
			expect(run(["changed"], {}).result).toEqual({ exit: 2, err: ["scripts/mutate.ts: base ref 'origin/main' not found; fetch origin first."] });
			expect(run(["changed"], HEAD).result).toEqual({ exit: 2, err: ["scripts/mutate.ts: git diff --merge-base origin/main failed."] });
		});
	});

	describe("staged", () => {
		const STAGED = { "write-tree": "t1\n", ...CLEAN, [diffArgs("--cached")]: ADDED };

		test("mutates the staged lines through the commit's index", () => {
			const r = run(["staged"], { ...STAGED, "rev-parse --verify --quiet HEAD": { status: 1, out: "" } });
			expect(r.result).toMatchObject({ mode: "staged", label: "staged", scope: ["--staged"], index: "/r/.git/index", tree: "t1", record: true });
		});

		// The commit's other lib lines come from HEAD.
		test("will record the commit only when HEAD's lib lines passed too", () => {
			const onHead = { ...STAGED, "rev-parse --verify --quiet HEAD": "h\n" };
			expect(run(["staged"], onHead).result).toMatchObject({ record: false });
			expect(run(["staged"], onHead, { has: ["mutated HEAD"] }).result).toMatchObject({ record: true });
			expect(run(["staged"], { ...onHead, "merge-base --is-ancestor HEAD origin/main": "" }).result).toMatchObject({ record: true });
		});

		test("will record nothing beside an untracked file", () => {
			const r = run(["staged"], { ...STAGED, "ls-files --others --exclude-standard": "new.txt\n" });
			expect(r.result).toMatchObject({ record: false });
		});

		test("with no lib line staged, records a gated commit and passes", () => {
			const r = run(["staged"], { ...STAGED, [diffArgs("--cached")]: DELETED }, { has: ["mutated HEAD"] });
			expect(r.result).toEqual({ exit: 0, out: ["scripts/mutate.ts: no lib/**/*.ex lines staged — nothing to mutate."] });
			expect(r.marked).toEqual(["mutated t1"]);
		});

		// An external diff tool or textconv filter would hide the lines.
		test("reads the diff git itself makes", () => {
			const r = run(["staged"], STAGED);
			expect(r.ran).toContain(diffArgs("--cached"));
		});
	});
});

test("announce names the files or the lines", () => {
	const base = { label: "selected", index: undefined, extra: [], tree: "", record: false };
	expect(announce({ ...base, mode: "paths", files: ["lib/a.ex", "lib/b.ex"], scope: [] })).toEqual([
		"scripts/mutate.ts: mutating 2 file(s):",
		"  lib/a.ex",
		"  lib/b.ex",
	]);
	expect(announce({ ...base, mode: "staged", files: ["lib/a.ex"], scope: ["--staged"] })).toEqual([
		"scripts/mutate.ts: mutating the staged lines of lib/**/*.ex.",
	]);
});

describe("listMutants", () => {
	test("lists each mutant with the lines its patch changes", () => {
		expect(listMutants([mutant("killed"), mutant("survived")], ["survived"])).toEqual([
			"lib/meerkat/one.ex:2  survived  Comparison: == to !=\n    - a == b\n    + a != b",
		]);
	});

	test("shows at most six lines a side, and none both sides share", () => {
		const before = ["keep", "1", "2", "3", "4", "5", "6", "7"].join("\n");
		const m = { ...mutant("survived"), patch: { before, after: "keep" } };
		expect(listMutants([m], ["survived"])[0]).toBe(
			"lib/meerkat/one.ex:2  survived  Comparison: == to !=\n    - 1\n    - 2\n    - 3\n    - 4\n    - 5\n    - 6\n    - …",
		);
	});

	test("lists a mutant without a patch on its own line", () => {
		expect(listMutants([{ ...mutant("timeout"), patch: null }], ["timeout"])).toEqual(["lib/meerkat/one.ex:2  timeout  Comparison: == to !="]);
	});
});

describe("judge", () => {
	const staged = { label: "staged", mode: "staged" };

	for (const status of ["survived", "no_coverage"]) {
		test(`fails on a ${status} mutant, listing it as untested behaviour`, () => {
			const d = judge([mutant("killed"), mutant(status)], staged);
			expect(d.exit).toBe(1);
			const out = (d.out ?? []).join("\n");
			expect(out).toContain("scripts/mutate.ts: staged lib/ lines have untested behaviour:");
			expect(out).toContain(`lib/meerkat/one.ex:2  ${status}  Comparison: == to !=\n    - a == b\n    + a != b`);
			expect(out).toContain("Add or tighten a test that fails for each mutant above, in this commit.");
			expect(out).not.toContain("  killed  ");
			expect(out).not.toContain("no test judged");
		});
	}

	// A test BEAM on a loaded machine can print nothing for most of a minute,
	// so a timed-out mutant tells nothing about the tests.
	test("fails on a timed-out mutant apart from untested behaviour", () => {
		const out = (judge([mutant("killed"), mutant("timeout")], staged).out ?? []).join("\n");
		expect(out).toContain("no test judged these mutants of the staged lib/ lines");
		expect(out).toContain("lib/meerkat/one.ex:2  timeout  Comparison: == to !=");
		expect(out).toContain("Rerun once the machine is less loaded.");
		expect(out).not.toContain("untested behaviour");
	});

	test("lists survivors and timed-out mutants each under its own heading", () => {
		const d = judge([mutant("survived", 2), mutant("timeout", 3)], { label: "changed", mode: "changed" });
		const [survivors, timeouts] = (d.out ?? []).join("\n").split("no test judged these mutants");
		expect(survivors).toContain("lib/meerkat/one.ex:2  survived  ");
		expect(survivors).toContain("in this branch.");
		expect(survivors).not.toContain("lib/meerkat/one.ex:3");
		expect(timeouts).toContain("lib/meerkat/one.ex:3  timeout  ");
		expect(timeouts).not.toContain("lib/meerkat/one.ex:2");
	});

	test("passes killed, invalid, equivalent and ignored mutants, and none", () => {
		expect(judge(["killed", "invalid", "equivalent", "ignored"].map((s) => mutant(s)), staged)).toEqual({ exit: 0, out: [] });
		expect(judge([], staged)).toEqual({ exit: 0, out: [] });
	});

	test("refuses a status it does not know", () => {
		expect(judge([mutant("killed"), mutant("pending"), mutant("new"), mutant("pending")], staged)).toEqual({
			exit: 2,
			err: ["scripts/mutate.ts: muex reported unknown mutant status(es): new, pending."],
		});
	});
});

describe("the muex run", () => {
	const RUN: Run = {
		mode: "staged",
		label: "staged",
		files: ["lib/meerkat/one.ex", "lib/meerkat/two.ex"],
		scope: ["--staged"],
		index: "/r/.git/index.lock",
		extra: [],
		tree: "t1",
		record: true,
	};

	test("keeps every mutant of the lines selected and judges by the report", () => {
		expect(muexArgs({ ...RUN, extra: ["--max-mutations", "1"] }, ["test/a_test.exs", "test/b_test.exs"], 4, "/r/_build/m.json")).toEqual(
			[
				"mix muex --files lib/meerkat/one.ex,lib/meerkat/two.ex --test-paths test/a_test.exs,test/b_test.exs",
				"--coverage-guided --concurrency 4 --no-filter --no-optimize --timeout 900000 --staged",
				"--fail-at 0 --format json --output /r/_build/m.json --max-mutations 1",
			]
				.join(" ")
				.split(" "),
		);
	});

	test("runs half the cores' worth of test BEAMs, at least one", () => {
		expect([jobsFor(1), jobsFor(2), jobsFor(9), jobsFor(16)]).toEqual([1, 1, 4, 8]);
	});

	test("leaves out the test files that drive scripts in subprocesses", () => {
		expect(testPaths(["test/meerkat/one_test.exs", "test/scripts/gate_test.exs", "test/web/two_test.exs"])).toEqual([
			"test/meerkat/one_test.exs",
			"test/web/two_test.exs",
		]);
	});

	const runGated = (
		run: Run,
		{ report = [mutant("killed")] as Mutation[] | null, fail = "", holding = true, muexStatus = 0 } = {},
	) => {
		const { g } = fakeGit({
			"rev-parse --local-env-vars": "GIT_DIR\nGIT_INDEX_FILE\n",
			"diff --quiet t1^{tree} --": holding ? "" : { status: 1, out: "" },
			"ls-files --others --exclude-standard": "",
		});
		const { r, marked } = memoryRecords();
		const events: string[] = [];
		const envs: Record<string, unknown>[] = [];
		const lines: string[] = [];
		const io: GatedIo = {
			git: g,
			records: r,
			env: { PATH: "/bin", GIT_DIR: "/r/.git", GIT_INDEX_FILE: "/r/.git/index.lock" },
			root: "/r",
			cores: 8,
			find: () => ["test/meerkat/one_test.exs", "test/scripts/gate_test.exs"],
			run: (cmd, env) => {
				const c = cmd.slice(0, 2).join(" ");
				events.push(c);
				envs.push(env);
				if (c === "mix muex") return muexStatus;
				return cmd.join(" ") === fail ? 3 : 0;
			},
			readReport: () => report,
			removeReport: (p) => events.push(`rm ${p}`),
			log: (l) => lines.push(l),
			err: (l) => lines.push(l),
		};
		return { status: gated(run, io), events, envs, marked, out: lines.join("\n") };
	};

	test("prepares the suite, removes the last run's report, runs muex, and records what passed", () => {
		const r = runGated(RUN);
		expect(r.status).toBe(0);
		expect(r.events).toEqual(["mix deps.get", "pnpm install", "mix compile", "rm /r/_build/mutate-staged.json", "mix muex"]);
		expect(r.envs[0]).toEqual({ PATH: "/bin", MIX_ENV: "test" });
		expect(r.envs[1]).toEqual({ PATH: "/bin" });
		expect(r.envs[2]).toEqual({ PATH: "/bin", MIX_ENV: "test" });
		// muex alone reads the commit's index.
		expect(r.envs[3]).toEqual({ PATH: "/bin", GIT_INDEX_FILE: "/r/.git/index.lock" });
		expect(r.marked).toEqual(["mutated t1"]);
		expect(r.out).toBe("scripts/mutate.ts: no mutant of the staged lib/ lines survived.");
	});

	test("a failing step or muex run fails the run and records nothing", () => {
		expect(runGated(RUN, { fail: "mix compile --warnings-as-errors" })).toMatchObject({ status: 3, marked: [] });
		expect(runGated(RUN, { muexStatus: 1 })).toMatchObject({ status: 1, marked: [] });
	});

	test("lines that produce no mutants pass", () => {
		const r = runGated(RUN, { report: null });
		expect(r).toMatchObject({ status: 0, marked: ["mutated t1"], out: "scripts/mutate.ts: the staged lib/ lines produce no mutants." });
	});

	test("a surviving mutant fails the run and records nothing", () => {
		const r = runGated(RUN, { report: [mutant("survived")] });
		expect(r.status).toBe(1);
		expect(r.marked).toEqual([]);
		expect(r.out).toContain("lib/meerkat/one.ex:2  survived");
	});

	test("records nothing when told not to or when the worktree changed while muex ran", () => {
		expect(runGated({ ...RUN, record: false }).marked).toEqual([]);
		expect(runGated(RUN, { holding: false })).toMatchObject({ status: 0, marked: [] });
	});

	test("a run without an index of its own gives muex none", () => {
		const r = runGated({ ...RUN, mode: "paths", label: "selected", scope: [], index: undefined, record: false });
		expect(r.envs[3]).toEqual({ PATH: "/bin" });
	});
});

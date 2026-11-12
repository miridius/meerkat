import { describe, expect, test } from "bun:test";
import type { GitResult, Records, Store } from "./checked-trees";
import { fakeGit } from "./fake-git";
import { bringsMerges, commitsOf, type Io, runGates, verifiedPush } from "./verified-push";

const A = "a".repeat(40);
const B = "b".repeat(40);
const HEAD = "h".repeat(40);

// A repo whose HEAD is HEAD, whose commits are A, B and HEAD, and which
// holds no merge commit the remotes lack.
const REPO: Record<string, GitResult | string> = {
	"rev-parse HEAD": `${HEAD}\n`,
	[`rev-list --min-parents=2 ${A} --not --remotes`]: "",
	[`rev-list --min-parents=2 ${B} --not --remotes`]: "",
	[`rev-list --min-parents=2 ${HEAD} --not --remotes`]: "",
	[`rev-list --min-parents=2 ${A} ${HEAD} --not --remotes`]: "",
	[`rev-parse --short ${A}`]: "aaaaaaa\n",
	[`rev-parse --short ${HEAD}`]: "hhhhhhh\n",
	[`diff --quiet ${HEAD}^{tree} --`]: "",
	"ls-files --others --exclude-standard": "",
};
for (const c of [A, B, HEAD]) {
	REPO[`rev-parse --verify --quiet ${c}^{}`] = `${c}\n`;
	REPO[`cat-file -t ${c}`] = "commit\n";
}

// Runs the hook for `shas` with `recorded` already recorded. A gate it runs
// records its commit unless it is in `fail` or `noMark`; `elsewhereFails`
// makes the temporary worktree fail.
async function push(
	shas: string[],
	{ recorded = [] as string[], fail = [] as string[], noMark = false, answers = {}, elsewhereFails = false } = {},
) {
	const marks = new Set(recorded);
	const r: Records = {
		has: (s: Store, c) => marks.has(`${s} ${c}`),
		mark: () => true,
	};
	const ran: string[] = [];
	const errs: string[] = [];
	const { g } = fakeGit({ ...REPO, ...answers });
	let current = HEAD;
	const io: Io = {
		git: g,
		records: r,
		err: (l) => errs.push(l),
		env: { PATH: "/bin", BASE_BRANCH: "feature" },
		run: async (cmd, opts = {}) => {
			const gate = cmd[1] === "scripts/check.ts" ? "check" : "mutate";
			ran.push(`${gate} ${current.slice(0, 1)}${opts.dir ? ` in ${opts.dir}` : ""}${opts.env?.BASE_BRANCH ? ` vs ${opts.env.BASE_BRANCH}` : ""}`);
			if (fail.includes(gate)) return 1;
			if (!noMark) marks.add(`${gate === "check" ? "checked" : "mutated"} ${current}`);
			return 0;
		},
		elsewhere: async (commit, gates) => {
			if (elsewhereFails) return false;
			current = commit;
			const ok = await gates("/tmp/x/tree", { PATH: "/bin" });
			current = HEAD;
			return ok;
		},
	};
	const status = await verifiedPush(shas, io);
	return { status, ran, errs: errs.join("\n") };
}

describe("commitsOf", () => {
	test("peels tags to commits, skips other objects, and refuses what git cannot read", () => {
		const errs: string[] = [];
		const { g } = fakeGit({
			"rev-parse --verify --quiet v1^{}": `${A}\n`,
			[`cat-file -t ${A}`]: "commit\n",
			"rev-parse --verify --quiet blob1^{}": "blob1\n",
			"cat-file -t blob1": "blob\n",
		});
		expect(commitsOf(["v1", "blob1", "1111"], { git: g, err: (l) => errs.push(l) })).toEqual({ commits: [A], status: 1 });
		expect(errs).toEqual(["pre-push: cannot read 1111."]);
	});
});

describe("bringsMerges", () => {
	test("refuses merge commits no remote-tracking ref holds, listing them", () => {
		const errs: string[] = [];
		const { g } = fakeGit({
			[`rev-list --min-parents=2 ${A} --not --remotes`]: "m1\nm2\n",
			"log --no-walk --format=  %h %s m1 m2": "  m1 Merge one\n  m2 Merge two\n",
		});
		expect(bringsMerges([A], { git: g, err: (l) => errs.push(l) })).toBe(true);
		expect(errs).toEqual(["pre-push: merge commits are refused; rebase onto main instead:", "  m1 Merge one\n  m2 Merge two"]);
	});

	test("lets the push through when the remotes hold every merge", () => {
		const { g } = fakeGit({ [`rev-list --min-parents=2 ${A} --not --remotes`]: "" });
		expect(bringsMerges([A], { git: g, err: () => {} })).toBe(false);
	});

	test("refuses the push when git cannot list the commits", () => {
		const errs: string[] = [];
		expect(bringsMerges([A], { git: fakeGit({}).g, err: (l) => errs.push(l) })).toBe(true);
		expect(errs).toEqual(["pre-push: cannot list the commits being pushed."]);
	});
});

describe("verifiedPush", () => {
	test("pushes a tip already checked without checking it again", async () => {
		expect(await push([HEAD], { recorded: [`checked ${HEAD}`, `mutated ${HEAD}`] })).toEqual({ status: 0, ran: [], errs: "" });
	});

	test("checks an unchecked HEAD in a clean worktree, then mutation-tests it against origin/main", async () => {
		const r = await push([HEAD]);
		expect(r.status).toBe(0);
		expect(r.ran).toEqual(["check h", "mutate h vs origin/main"]);
		expect(r.errs).toContain("checking it now");
	});

	// A BASE_BRANCH the user exported does not narrow the lines mutated.
	test("mutation-tests a checked HEAD the mutation gate never recorded", async () => {
		expect((await push([HEAD], { recorded: [`checked ${HEAD}`] })).ran).toEqual(["mutate h vs origin/main"]);
	});

	test("refuses an unchecked HEAD whose gates fail, stopping at the first", async () => {
		expect(await push([HEAD], { fail: ["check"] })).toMatchObject({ status: 1, ran: ["check h"] });
		expect(await push([HEAD], { fail: ["mutate"] })).toMatchObject({ status: 1, ran: ["check h", "mutate h vs origin/main"] });
	});

	test("refuses an unchecked HEAD beside uncommitted or untracked files, unchecked", async () => {
		const r = await push([HEAD], { answers: { "ls-files --others --exclude-standard": "stray.txt\n" } });
		expect(r).toMatchObject({ status: 1, ran: [] });
		expect(r.errs).toContain("uncommitted or untracked files");
	});

	test("refuses an unchecked HEAD that its gates did not record, as the worktree changed", async () => {
		const r = await push([HEAD], { noMark: true });
		expect(r.status).toBe(1);
		expect(r.errs).toContain("the worktree changed while HEAD (hhhhhhh) was being checked");
	});

	test("checks an unchecked tip other than HEAD in a temporary worktree", async () => {
		const r = await push([A]);
		expect(r.status).toBe(0);
		expect(r.ran).toEqual(["check a in /tmp/x/tree", "mutate a in /tmp/x/tree vs origin/main"]);
		expect(r.errs).toContain("aaaaaaa has not passed the commit gate; checking it now in a");
	});

	test("refuses a tip other than HEAD whose gates fail, whose worktree cannot be made, or that records nothing", async () => {
		for (const gate of ["check", "mutate"]) {
			const r = await push([A], { fail: [gate] });
			expect(r.status).toBe(1);
			expect(r.errs).toContain("aaaaaaa failed the commit gate.");
		}
		expect((await push([A], { elsewhereFails: true })).errs).toContain("aaaaaaa failed the commit gate.");
		expect((await push([A], { noMark: true })).errs).toContain("aaaaaaa passed the commit gate but was not recorded.");
	});

	test("checks a stack's lower branch and its HEAD", async () => {
		expect((await push([A, HEAD])).ran).toEqual([
			"check a in /tmp/x/tree",
			"mutate a in /tmp/x/tree vs origin/main",
			"check h",
			"mutate h vs origin/main",
		]);
	});

	test("still checks, and fails, an unchecked tip after a checked one or a non-commit", async () => {
		const r = await push([HEAD, A], {
			recorded: [`checked ${HEAD}`, `mutated ${HEAD}`],
			fail: ["check"],
			answers: { [`rev-list --min-parents=2 ${HEAD} ${A} --not --remotes`]: "" },
		});
		expect(r).toMatchObject({ status: 1, ran: ["check a in /tmp/x/tree"] });
		const blob = await push(["blob1", A], {
			fail: ["check"],
			answers: { "rev-parse --verify --quiet blob1^{}": "blob1\n", "cat-file -t blob1": "blob\n" },
		});
		expect(blob.status).toBe(1);
	});

	test("skips a tag of something other than a commit", async () => {
		const r = await push(["blob1"], { answers: { "rev-parse --verify --quiet blob1^{}": "blob1\n", "cat-file -t blob1": "blob\n" } });
		expect(r).toEqual({ status: 0, ran: [], errs: "" });
	});

	test("refuses a push bringing a merge commit before any gate runs", async () => {
		const r = await push([HEAD], {
			answers: { [`rev-list --min-parents=2 ${HEAD} --not --remotes`]: "m1\n", "log --no-walk --format=  %h %s m1": "  m1 Merge\n" },
		});
		expect(r).toMatchObject({ status: 1, ran: [] });
		expect(r.errs).toContain("merge commits are refused");
	});

	test("refuses a tip git cannot read", async () => {
		expect(await push(["1111"])).toEqual({ status: 1, ran: [], errs: "pre-push: cannot read 1111." });
	});
});

test("runGates runs in the directory and environment given", async () => {
	const ran: unknown[] = [];
	const io = {
		records: { has: () => false, mark: () => true },
		env: { PATH: "/x" },
		run: async (cmd: string[], opts: unknown) => {
			ran.push({ cmd, opts });
			return 0;
		},
	} as unknown as Io;
	expect(await runGates(A, io, "/t", { PATH: "/bin" })).toBe(true);
	expect(ran).toEqual([
		{ cmd: ["bun", "scripts/check.ts", "--head"], opts: { dir: "/t", env: { PATH: "/bin" } } },
		{ cmd: ["bun", "scripts/mutate.ts", "changed"], opts: { dir: "/t", env: { PATH: "/bin", BASE_BRANCH: "origin/main" } } },
	]);
});

import { describe, expect, test } from "bun:test";
import { type Git, holds, key, keyed, main, type Marks, records } from "./checked-trees";
import { fakeGit } from "./fake-git";

const LISTING = [
	"100644 blob aaaa\tREADME.md",
	"100644 blob bbbb\tlib/meerkat/git.ex",
	"100644 blob cccc\tdocs/features/cli.md",
	"100644 blob dddd\tscripts/mix-test.sh",
	"100644 blob eeee\ttest/scripts/x_test.exs",
	"",
].join("\n");

describe("keyed", () => {
	test("keys the gates' records on every file but Markdown, one line each", () => {
		const want = "100644 blob bbbb\tlib/meerkat/git.ex\n100644 blob dddd\tscripts/mix-test.sh\n100644 blob eeee\ttest/scripts/x_test.exs\n";
		expect(keyed("checked", LISTING)).toBe(want);
		expect(keyed("mutated", LISTING)).toBe(want);
	});

	test("matches .md only at the end of a path", () => {
		expect(keyed("checked", "100644 blob aaaa\tdocs.md/x.ex\n")).toBe("100644 blob aaaa\tdocs.md/x.ex\n");
	});

	// So contents that differ only outside the e2e inputs share a record.
	test("keys the e2e record on the e2e inputs alone", () => {
		expect(keyed("e2e", LISTING)).toBe("100644 blob bbbb\tlib/meerkat/git.ex\n");
	});

	test("keys contents with nothing kept on the empty listing", () => {
		expect(keyed("e2e", "100644 blob aaaa\tREADME.md\n")).toBe("");
	});
});

describe("key", () => {
	test("hashes the kept lines of the full tree's listing", () => {
		const { g, ran } = fakeGit({
			"ls-tree -r --full-tree HEAD^{tree}": LISTING,
			"hash-object --stdin": "abc123\n",
		});
		expect(key(g, "e2e", "HEAD")).toBe("abc123");
		expect(ran[1].input).toBe("100644 blob bbbb\tlib/meerkat/git.ex\n");
	});

	test("is null when git cannot list or hash the contents", () => {
		expect(key(fakeGit({}).g, "checked", "nope")).toBeNull();
		expect(key(fakeGit({ "ls-tree -r --full-tree HEAD^{tree}": LISTING }).g, "checked", "HEAD")).toBeNull();
	});
});

describe("records", () => {
	const repo = {
		"ls-tree -r --full-tree t1^{tree}": LISTING,
		"ls-tree -r --full-tree t2^{tree}": `${LISTING}100644 blob ffff\tnotes.md\n`,
		"ls-tree -r --full-tree t3^{tree}": `${LISTING}100644 blob ffff\tmix.exs\n`,
		"rev-parse --path-format=absolute --git-common-dir": "/repo/.git\n",
	};
	// hash-object answers with the input, so the key shows what it covers.
	const g: Git = (args, opts) =>
		args[0] === "hash-object" ? { status: 0, out: `${opts?.input}` } : fakeGit(repo).g(args, opts);

	const memory = () => {
		const store = new Map<string, Set<string>>();
		const marks = (dir: string): Marks => {
			const keys = store.get(dir) ?? new Set();
			store.set(dir, keys);
			return { has: (k) => keys.has(k), mark: (k) => void keys.add(k) };
		};
		return { store, r: records(g, marks) };
	};

	test("finds marked contents in their own store in the git common dir only", () => {
		const { store, r } = memory();
		expect(r.has("checked", "t1")).toBe(false);
		expect(r.mark("checked", "t1")).toBe(true);
		expect(r.has("checked", "t1")).toBe(true);
		expect(r.has("mutated", "t1")).toBe(false);
		expect(r.has("e2e", "t1")).toBe(false);
		expect([...store.keys()].sort()).toEqual(["/repo/.git/meerkat-checked", "/repo/.git/meerkat-e2e", "/repo/.git/meerkat-mutated"]);
	});

	test("a commit adding only Markdown counts as checked when its parent was", () => {
		const { r } = memory();
		r.mark("checked", "t1");
		expect(r.has("checked", "t2")).toBe(true);
		expect(r.has("checked", "t3")).toBe(false);
	});

	test("cannot mark or find contents git cannot list", () => {
		const { r } = memory();
		expect(r.mark("checked", "missing")).toBe(false);
		expect(r.has("checked", "missing")).toBe(false);
	});
});

describe("holds", () => {
	const clean = { "diff --quiet t^{tree} --": "", "ls-files --others --exclude-standard": "" };

	test("holds when the worktree matches the tree and nothing is untracked", () => {
		expect(holds(fakeGit(clean).g, "t")).toBe(true);
	});

	test("does not hold beside an untracked file, an unstaged change, or a git error", () => {
		expect(holds(fakeGit({ ...clean, "ls-files --others --exclude-standard": "new.txt\n" }).g, "t")).toBe(false);
		expect(holds(fakeGit({ ...clean, "diff --quiet t^{tree} --": { status: 1, out: "" } }).g, "t")).toBe(false);
		expect(holds(fakeGit({ "diff --quiet t^{tree} --": "" }).g, "t")).toBe(false);
	});

	test("runs git in the environment given", () => {
		const { g, ran } = fakeGit(clean);
		holds(g, "t", { PATH: "/bin" });
		expect(ran.map((r) => r.env)).toEqual([{ PATH: "/bin" }, { PATH: "/bin" }]);
	});
});

describe("main", () => {
	const calls: string[] = [];
	const r = {
		has: (s: string, rev: string) => {
			calls.push(`has ${s} ${rev}`);
			return rev === "yes";
		},
		mark: (s: string, rev: string) => {
			calls.push(`mark ${s} ${rev}`);
			return rev !== "bad";
		},
	};

	test("marks and looks up each store", () => {
		const g = fakeGit({}).g;
		expect(main(["mark", "HEAD"], g, r)).toBe(0);
		expect(main(["--mutated", "mark", "HEAD"], g, r)).toBe(0);
		expect(main(["--e2e", "has", "yes"], g, r)).toBe(0);
		expect(main(["has", "no"], g, r)).toBe(1);
		expect(main(["mark", "bad"], g, r)).toBe(1);
		expect(calls).toEqual(["mark checked HEAD", "mark mutated HEAD", "has e2e yes", "has checked no", "mark checked bad"]);
	});

	test("answers holds from the worktree", () => {
		const g = fakeGit({ "diff --quiet t^{tree} --": "", "ls-files --others --exclude-standard": "x\n" }).g;
		expect(main(["holds", "t"], g, r)).toBe(1);
	});

	test("refuses any other usage", () => {
		const g = fakeGit({}).g;
		for (const args of [[], ["has"], ["has", "a", "b"], ["--other", "has", "a"], ["drop", "a"]]) {
			expect(main(args, g, r)).toBe(2);
		}
	});
});

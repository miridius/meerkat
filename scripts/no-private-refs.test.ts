import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
	addedLines,
	collect,
	combine,
	dropAllowed,
	dropInvalidUtf8,
	Git,
	askRemote,
	lintPrivate,
	main,
	mergeBinaryPaths,
	PATTERNS,
	parseArgs,
	parsePrivate,
	pass,
	published,
	Refusal,
	refNameLines,
	report,
	scan,
	selfTest,
	utf8Locale,
} from "./no-private-refs";

// The git tests start git processes, which on a loaded machine can take
// longer than bun's 5 s default.
setDefaultTimeout(60_000);

// Assembled from pieces: this file is itself scanned before every push.
const PRIVATE_PATH = "/Us" + "ers/alice/notes";
const ACME = { line: 3, regex: "(^|[^a-z])acme-internal([^a-z]|$)" };
const FILE = ".git/info/private-refs";

const latin1 = (b: Buffer) => b.toString("latin1");

describe("parsePrivate", () => {
	test("numbers each pattern by its line, skipping comments and blank lines", () => {
		expect(parsePrivate("# private names\n\nacme\n#x\nbeta\n")).toEqual([
			{ line: 3, regex: "acme" },
			{ line: 5, regex: "beta" },
		]);
	});

	test("drops CRLF line endings and a byte-order mark", () => {
		expect(parsePrivate("# names\r\nacme\r\n")).toEqual([{ line: 2, regex: "acme" }]);
		expect(parsePrivate("\ufeffacme\n")).toEqual([{ line: 1, regex: "acme" }]);
	});

	test("counts the last pattern without a trailing newline", () => {
		expect(parsePrivate("acme")).toEqual([{ line: 1, regex: "acme" }]);
	});

	test("keeps a carriage return inside a line, for the lint to refuse", () => {
		expect(parsePrivate("acme\rzzz\r")).toEqual([{ line: 1, regex: "acme\rzzz" }]);
	});
});

describe("lintPrivate", () => {
	// git grep's ERE reads `\d` as a plain `d`, so the scan would silently
	// miss `acme1x`.
	test("refuses a backslash escape but not an escaped backslash", () => {
		expect(lintPrivate("acme\\dx")).toContain("backslash escape");
		expect(lintPrivate("[[:<:]]acme\\<")).toContain("backslash escape");
		expect(lintPrivate("acme\\\\dev")).toBeUndefined();
	});

	test("refuses a control character and surrounding whitespace", () => {
		expect(lintPrivate("acme\rzzz")).toContain("control character");
		expect(lintPrivate("acme\t")).toContain("control character");
		expect(lintPrivate("acme-internal ")).toContain("whitespace");
		expect(lintPrivate(" acme")).toContain("whitespace");
	});

	test("passes a pattern starting with a dash", () => {
		expect(lintPrivate("-internal-x")).toBeUndefined();
	});
});

describe("dropAllowed", () => {
	test("drops placeholder and no-reply addresses in any case, at the start of a line too", () => {
		const hits = [
			"commit-1:4:noreply@anthropic.com",
			"a.txt:1:Test@Example.COM",
			"HEAD:a.txt:2:noreply@github.com",
			"b.txt:1:1+bot@users.noreply.github.com",
		];
		expect(dropAllowed(hits)).toEqual([]);
	});

	test("keeps other addresses, a placeholder domain used as a prefix among them", () => {
		const spoof = "a.txt:1:x@" + "example.com.evil.io";
		expect(dropAllowed(["a.txt:1:bob@" + "acme.io", spoof])).toEqual(["a.txt:1:bob@" + "acme.io", spoof]);
	});
});

describe("searches", () => {
	test("a pass that exits 0 having printed nothing matched empty text", () => {
		expect(pass(0, "", "").status).toBe(3);
		expect(pass(0, "a:1:x\n", "")).toEqual({ status: 0, hits: ["a:1:x"], err: "" });
		expect(pass(1, "", "").status).toBe(1);
		expect(pass(128, "", "fatal").status).toBe(2);
	});

	test("combine reports either pass's hits once, and its worst failure", () => {
		const hit = (...hits: string[]) => ({ status: 0 as const, hits, err: "" });
		const none = { status: 1 as const, hits: [], err: "" };
		expect(combine(hit("b", "a"), hit("a", "c")).hits).toEqual(["a", "b", "c"]);
		expect(combine(none, hit("a"))).toEqual(hit("a"));
		expect(combine(none, none).status).toBe(1);
		expect(combine({ ...none, status: 3 }, hit("a")).status).toBe(3);
		expect(combine({ ...none, status: 3 }, { ...none, status: 2 }).status).toBe(2);
	});
});

describe("dropInvalidUtf8", () => {
	test("drops each byte outside a valid character and keeps the rest", () => {
		const input = Buffer.from("M\xc3\xbcller \xff\n\xc3(\xed\xa0\x80\xc0\xaf\xe2\x82\xac\n", "latin1");
		expect(latin1(dropInvalidUtf8(input))).toBe("M\xc3\xbcller \n(\xe2\x82\xac\n");
	});

	// macOS iconv drops a cut-off character at the end of its input together
	// with the newlines after it, which once made a copy one line short.
	test("keeps the newlines after a cut-off character", () => {
		for (const tail of ["\xf0", "\xfc"])
			expect(latin1(dropInvalidUtf8(Buffer.from(`thanks ${tail}\n\n`, "latin1")))).toBe("thanks \n\n");
	});
});

describe("addedLines", () => {
	test("keeps only lines every parent lacks, without their markers or file headers", () => {
		const diff = [
			"diff --git a/a.md b/a.md",
			"index 1..2 100644",
			"--- a/a.md",
			"+++ b/a.md",
			"@@ -1,2 +1,2 @@",
			"-line1",
			"+LINE1",
			// A context line can start with spaces and `+` of its own.
			"   + acme-internal item",
		].join("\n");
		expect(addedLines(diff, 1)).toBe("LINE1\n");
	});

	test("a merge's line is added only when it is `+` in every parent's column", () => {
		const diff = ["diff --cc a.txt", "index 1,2..3", "@@@ -1,2 -1,3 +1,4 @@@", "  a", " +side", "++acme-internal", "  b"].join(
			"\n",
		);
		expect(addedLines(diff, 2)).toBe("acme-internal\n");
	});

	test("a root commit's lines lose their one marker", () => {
		expect(addedLines("diff --git a/a b/a\nnew file mode 100644\n@@ -0,0 +1 @@\n+acme-internal", 0)).toBe("acme-internal\n");
	});
});

describe("mergeBinaryPaths", () => {
	test("names each binary file of a merge, its header's path", () => {
		const diff = "diff --cc t.txt\n@@@ x @@@\n diff --cc\ndiff --cc \xc3\xa9.dat\nBinary files differ\ndiff --cc y.dat\nBinary files differ\n";
		expect(mergeBinaryPaths(diff, "m")).toEqual(["é.dat", "y.dat"]);
	});

	test("refuses a path git quotes", () => {
		expect(() => mergeBinaryPaths('diff --cc "x\\"y.dat"\nBinary files differ\n', "m")).toThrow(
			'cannot read binary file "x\\"y.dat" in merge m',
		);
	});
});

test("refNameLines gives each ref in full and without its kind", () => {
	expect(refNameLines(["refs/heads/acme-internal-fix", "refs/tags/v1"])).toBe(
		"refs/heads/acme-internal-fix\nacme-internal-fix\nrefs/tags/v1\nv1\n",
	);
});

describe("published", () => {
	const ls = "a1\trefs/heads/main\nb2\trefs/heads/ahead\nc3\trefs/pull/1/head\n";

	test("excludes the remote's objects this clone has", () => {
		expect(published(ls, "a1 commit 200\nb2 missing\nc3 missing\n")).toEqual({ have: ["^a1"], ahead: true });
	});

	// A fetch does not bring in a host's pull-request refs.
	test("is ahead only for a missing branch or tag tip", () => {
		expect(published(ls, "a1 commit 200\nb2 commit 200\nc3 missing\n").ahead).toBe(false);
	});

	// 3000 pull-request refs once filled a pipe, and a reader that stopped at
	// its first match killed the writer and lost the fetch hint.
	test("reads past many other refs", () => {
		const many = Array.from({ length: 3000 }, (_, i) => `p${i}\trefs/pull/${i}/head`).join("\n");
		const batch = Array.from({ length: 3000 }, (_, i) => `p${i} commit 1`).join("\n");
		expect(published(`${many}\nz\trefs/heads/main\n`, `${batch}\nz missing\n`).ahead).toBe(true);
	});
});

describe("parseArgs", () => {
	test("takes the remote, each ref and tip, and HEAD when given no tip", () => {
		expect(parseArgs(["--remote", "u", "--ref", "refs/heads/a", "t1", "t2"])).toEqual({
			remote: "u",
			refs: ["refs/heads/a"],
			tips: ["t1", "t2"],
		});
		expect(parseArgs([])).toEqual({ refs: [], tips: ["HEAD"] });
	});

	test("refuses an empty remote rather than trusting tracking branches", () => {
		expect(() => parseArgs(["--remote", "", "HEAD"])).toThrow("no remote to ask what it already has");
	});
});

describe("report", () => {
	const history = { label: "email address", where: "history" as const, hits: ["commit-1:4:bob@" + "acme.io"] };

	test("lists each finding's hits under its heading", () => {
		const out = report([history, { label: "email address", where: "tree", hits: ["HEAD:a:1:x"] }], false, FILE);
		expect(out).toContain("ERROR: email address in a commit, tag or ref name being pushed:\n    commit-1:4:bob@");
		expect(out).toContain("ERROR: email address in a tracked file:\n    HEAD:a:1:x\n");
		expect(out).toContain(`scripts/no-private-refs.ts or ${FILE} and push again;`);
		expect(out).not.toContain("git fetch");
	});

	test("says to fetch first only for a history hit while the remote is ahead", () => {
		expect(report([history], true, FILE)).toContain("Run `git fetch` and push again first.");
		const refName = { ...history, hits: ["ref-names:1:acme-internal-fix"] };
		expect(report([refName], true, FILE)).not.toContain("git fetch");
	});

	test("prints nothing for no findings", () => {
		expect(report([], true, FILE)).toBe("");
	});
});

// The tests below run git: git grep for every search, and git itself on a
// fixture repo built once, as one pack, and only read afterwards.
const env: Record<string, string | undefined> = {
	...process.env,
	GIT_CONFIG_GLOBAL: join(import.meta.dir, "../test/support/test.gitconfig"),
	GIT_CONFIG_NOSYSTEM: "1",
};
for (const name of ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY", "GIT_CONFIG_PARAMETERS"])
	delete env[name];

let base: string;
let locale: string;
const scratch = () => new Git(base, env);

beforeAll(() => {
	base = mkdtempSync(join(tmpdir(), "no-private-refs-test-"));
	locale = utf8Locale();
});
afterAll(() => rmSync(base, { recursive: true, force: true }));

// Scans literal texts, as `collect` would give them, for literal patterns.
const scanTexts = (texts: Record<string, string>, priv = [ACME]) =>
	scan(scratch(), locale, new Map(Object.entries(texts)), [], PATTERNS, priv, FILE);

describe("scan of literal texts", () => {
	test("finds a private pattern and an email address, each in its own object", () => {
		const findings = scanTexts({ "commit-1": "author t <dev@" + "acme.io>\n\nsee acme-internal docs\n", "diff-1": "a\n" });
		expect(findings).toEqual([
			{ label: "email address", where: "history", hits: ["commit-1:1:dev@" + "acme.io"] },
			{ label: `private pattern on line 3 of ${FILE}`, where: "history", hits: ["commit-1:3: acme-internal "] },
		]);
	});

	test("reports every address on a line but the allowed ones", () => {
		const spoof = "x@" + "example.com.evil.io";
		const line = `mail bob@${"acme.io"} or test@example.com or ${spoof}\n`;
		expect(scanTexts({ "diff-1": line })[0].hits).toEqual([`diff-1:1:bob@${"acme.io"}`, `diff-1:1:${spoof}`]);
	});

	test("does not read text whose domain label starts with a hyphen as an address", () => {
		expect(scanTexts({ "diff-1": "8\x94r@-2.kt\x80\n" })).toEqual([]);
	});

	test("finds the local path and session URL patterns", () => {
		const findings = scanTexts({ "commit-1": `copied from ${PRIVATE_PATH}\nsee https://claude.ai/code/${"session_01"}\n` });
		expect(findings.map((f) => f.label)).toEqual(["Claude Code session URL", "local absolute path"]);
	});

	test("reports a private match even when it ends in an allowed address", () => {
		const hits = scanTexts({ "diff-1": "acme-internal:ops@example.com\n" }, [{ line: 1, regex: "acme-internal[^ ]*" }]);
		expect(hits).toEqual([
			{ label: `private pattern on line 1 of ${FILE}`, where: "history", hits: ["diff-1:1:acme-internal:ops@example.com"] },
		]);
	});

	test("matches a quantified non-ASCII letter, which only the UTF-8 pass reads as one", () => {
		expect(scanTexts({ "diff-1": "see acmecorp docs\n" }, [{ line: 1, regex: "acmeä?corp" }])).toHaveLength(1);
	});

	// Bytes that are not valid UTF-8 must not hide a match on their line.
	test("matches a non-ASCII name beside a byte that is not valid UTF-8", () => {
		const findings = scanTexts({ "diff-1": "author: M\xc3\xbcller \xff\n" }, [{ line: 1, regex: "M[üu]ller" }]);
		expect(findings[0].hits).toEqual(["diff-1:1:M\xc3\xbcller"]);
	});

	test("reads a pattern starting with a dash as a pattern, not an option", () => {
		expect(scanTexts({ "diff-1": "acme-internal-x\n" }, [{ line: 1, regex: "-internal-x" }])).toHaveLength(1);
	});

	test("matches a literal backslash with an escaped one", () => {
		expect(scanTexts({ "diff-1": "C:\\acme\\dev\n" }, [{ line: 1, regex: "acme\\\\dev" }])).toHaveLength(1);
	});

	// Only BSD regexes have a word boundary without a backslash, which is how
	// a pattern can match empty text beside a word but not on its own.
	test.skipIf(process.platform !== "darwin")("refuses a pattern that matches empty text beside a word", () => {
		expect(() => scanTexts({ "diff-1": "see acme-internal docs\n" }, [{ line: 1, regex: "(acme-internal)?[[:<:]]" }])).toThrow(
			"matches empty text in the commits, tags and ref names being pushed",
		);
	});

	test("matches a start-anchored pattern against added lines and short ref names", () => {
		const texts = { "diff-1": addedLines("diff --git a/a b/a\n@@ -0,0 +1 @@\n+acme-internal: token", 1), "ref-names": refNameLines(["refs/heads/acme-internal-fix"]) };
		expect(scanTexts(texts, [{ line: 1, regex: "^acme-internal" }])[0].hits).toEqual([
			"diff-1:1:acme-internal",
			"ref-names:2:acme-internal",
		]);
	});
});

describe("selfTest", () => {
	test("passes the generic patterns", () => {
		expect(selfTest(scratch(), locale, PATTERNS, [], FILE)).toEqual([]);
	});

	test("fails a generic pattern that misses its own example or fires on its counter-example", () => {
		const address = "b.dev@" + "corp.io";
		const broken = PATTERNS.map((p) =>
			p.label === "email address" ? { ...p, match: "mail nobody now", miss: `mail ${address} now` } : p,
		);
		expect(selfTest(scratch(), locale, broken, [], FILE)).toEqual([
			"SELF-TEST: 'email address' misses its own example: mail nobody now",
			`SELF-TEST: 'email address' fires on its counter-example: mail ${address} now`,
		]);
	});

	test("names the line of a private pattern that is invalid, matches empty text, or fails the lint", () => {
		const failures = selfTest(
			scratch(),
			locale,
			[],
			[
				{ line: 3, regex: "acme(" },
				{ line: 4, regex: "(acme-internal)?" },
				{ line: 5, regex: "acme\\dx" },
				{ line: 6, regex: "acme-internal" },
			],
			FILE,
		);
		expect(failures).toHaveLength(3);
		expect(failures[0]).toStartWith(`SELF-TEST: line 3 of ${FILE} is not a valid regex: `);
		expect(failures[1]).toBe(`SELF-TEST: line 4 of ${FILE} matches empty text, so git grep cannot show its matches`);
		expect(failures[2]).toStartWith(`SELF-TEST: line 5 of ${FILE} has a backslash escape`);
	});
});

// A fixture repo `work`, with a bare remote `remote.git` whose `main` is
// work's `main` and which also has a branch and a pull-request ref work
// lacks. Each scenario is a branch of `work`, built by one fast-import.
describe("against a repo", () => {
	let work: string;
	let remote: string;
	let git: Git;
	const sha = (rev: string) => git.read(["rev-parse", rev], rev).trim();

	const T = "1700000000 +0000";
	type Change = [path: string, content: string | null];
	// A fast-import stream, as latin1 text: `data` counts bytes.
	class Stream {
		s = "";
		n = 0;
		data(d: string) {
			this.s += `data ${d.length}\n${d}\n`;
		}
		commit(ref: string, msg: string, changes: Change[], from?: string, merge?: string) {
			this.s += `commit ${ref}\nmark :${++this.n}\nauthor t <t@t.t> ${T}\ncommitter t <t@t.t> ${T}\n`;
			this.data(msg);
			if (from) this.s += `from ${from}\n`;
			if (merge) this.s += `merge ${merge}\n`;
			for (const [path, content] of changes) {
				if (content === null) this.s += `D ${path}\n`;
				else {
					this.s += `M 100644 inline ${path}\n`;
					this.data(content);
				}
			}
			return `:${this.n}`;
		}
	}
	const fastImport = (dir: string, s: Stream) => {
		const r = new Git(dir, env).run(["fast-import", "--quiet"], { stdin: s.s });
		if (r.status !== 0) throw new Error(r.err);
	};

	// Builds a merge of `side` into `main`, both from `base`, whose own
	// resolution of each file is `resolution`.
	const merge = (s: Stream, ref: string, from: string, ours: Change[], theirs: Change[], resolution: Change[]) => {
		const side = s.commit(`${ref}-side`, "side", theirs, from);
		const main = s.commit(ref, "main", ours, from);
		return s.commit(ref, "merge side", resolution, main, side);
	};

	beforeAll(() => {
		work = join(base, "work");
		remote = join(base, "remote.git");
		mkdirSync(join(work, ".git/info"), { recursive: true });
		const run = (dir: string, args: string[]) => {
			const r = new Git(dir, env).run(args);
			if (r.status !== 0) throw new Error(r.err);
		};
		run(work, ["init", "-q", "--initial-branch=main"]);
		run(base, ["init", "-q", "--bare", remote]);
		writeFileSync(join(work, ".git/info/private-refs"), `# private names\n\n${ACME.regex}\n`);
		git = new Git(work, env);

		const s = new Stream();
		const m0 = s.commit("refs/heads/main", "base", [
			["README.md", "hello\n"],
			["sub/x.txt", "x\n"],
		]);
		s.s += `reset refs/remotes/origin/main\nfrom ${m0}\n`;
		const bin = (t: string) => `\xff\xfe\x00${t}`;
		s.commit("refs/heads/below", "see acme-internal docs", [["a.txt", "a\n"]], m0);
		s.commit("refs/heads/below", "add b", [["b.txt", "b\n"]]);
		s.commit("refs/heads/readded", "add a", [["a.txt", "see acme-internal docs\n"]], m0);
		s.commit("refs/heads/readded", "reword a", [["a.txt", "see the docs\n"]]);
		s.commit("refs/heads/binary", "add x", [["x.dat", bin("see acme-internal docs\n")]], m0);
		s.commit("refs/heads/binary", "remove x", [["x.dat", null]]);
		s.commit("refs/heads/tracked-binary", "add x", [["x.dat", bin("see acme-internal docs\n")]], m0);
		s.commit("refs/heads/tracked-utf8", "add a", [["a.txt", "see acmecorp docs\n"]], m0);
		s.commit("refs/heads/root", "root", [["a.txt", "acme-internal\n"]]);
		s.commit("refs/heads/root", "reword a", [["a.txt", "clean\n"]]);
		s.commit("refs/heads/empty-file", "add notes", [["acme-internal-notes.md", ""]], m0);
		s.commit("refs/heads/emails", "Co-Authored-By: C <noreply@anthropic.com>", [["a.txt", "mail test@example.com\n"]], m0);
		// Public history, then commits that only edit beside or remove it.
		const pub = s.commit(
			"refs/heads/public",
			"add a",
			[
				["a.md", "line1\n  + acme-internal item\n"],
				["acme-internal.txt", "x\n"],
			],
			m0,
		);
		s.s += `reset refs/remotes/origin/public\nfrom ${pub}\n`;
		s.commit("refs/heads/public", "edit beside it", [
			["a.md", "LINE1\n  + acme-internal item\n"],
			["acme-internal.txt", "y\n"],
		]);
		s.commit("refs/heads/public", "remove it", [
			["a.md", "LINE1\n"],
			["acme-internal.txt", null],
		]);
		// A merge's own resolution adds a line a later commit removes.
		merge(s, "refs/heads/merge-adds", m0, [["c.txt", "c\n"]], [["b.txt", "b\n"]], [["c.txt", "c, see acme-internal docs\n"]]);
		s.commit("refs/heads/merge-adds", "reword c", [["c.txt", "c\n"]]);
		// A merge keeps a line one parent already has.
		const keep = s.commit("refs/heads/merge-keeps", "add a", [["a.txt", "a\nb\n"]], m0);
		merge(s, "refs/heads/merge-keeps", keep, [["a.txt", "a\nacme-internal\nb\n"]], [["a.txt", "a\nside\nb\n"]], [["a.txt", "a\nside\nacme-internal\nb\n"]]);
		// t.txt takes each hunk from one parent, so `--cc` shows only x.dat
		// while `--name-only` lists both: the path must come from the header.
		const binBase = s.commit("refs/heads/merge-binary", "add", [["t.txt", "1\n2\n3\n4\n5\n"], ["x.dat", bin("base\n")], ["\xc3\xa9.dat", bin("base\n")], ["y.dat", bin("base\n")]], m0);
		merge(
			s,
			"refs/heads/merge-binary",
			binBase,
			[["t.txt", "1\n2\n3\n4\nfive\n"], ["x.dat", bin("main\n")], ["\xc3\xa9.dat", bin("main\n")], ["y.dat", bin("main\n")]],
			[["t.txt", "one\n2\n3\n4\n5\n"], ["x.dat", bin("side\n")], ["\xc3\xa9.dat", bin("side\n")], ["y.dat", bin("side\n")]],
			[["t.txt", "one\n2\n3\n4\nfive\n"], ["x.dat", bin("see acme-internal docs\n")], ["\xc3\xa9.dat", "\xff\x00acme-"], ["y.dat", "internal\xff\x00"]],
		);
		s.commit("refs/heads/merge-binary", "reword", [["x.dat", bin("done\n")]]);
		const quoted = s.commit("refs/heads/merge-quoted", "add", [['x"y.dat', bin("base\n")]], m0);
		merge(s, "refs/heads/merge-quoted", quoted, [['x"y.dat', bin("main\n")]], [['x"y.dat', bin("side\n")]], [['x"y.dat', bin("clean\n")]]);
		const deleted = s.commit("refs/heads/merge-deletes", "add", [["x.dat", bin("base\n")]], m0);
		merge(s, "refs/heads/merge-deletes", deleted, [["x.dat", bin("main\n")]], [["x.dat", bin("side\n")]], [["x.dat", null]]);
		// A commit whose content a replace ref hides.
		s.commit("refs/heads/replaced", "add a", [["a.txt", "see acme-internal docs\n"]], m0);
		s.commit("refs/heads/replaced-clean", "add a", [], m0);
		s.commit("refs/heads/replaced", "reword a", [["a.txt", "see the docs\n"]]);
		s.s += `tag v1\nfrom ${m0}\ntagger t <t@t.t> ${T}\n`;
		s.data("release for acme-internal\n");
		fastImport(work, s);

		run(work, ["update-ref", `refs/replace/${sha("replaced~1")}`, sha("replaced-clean")]);
		run(work, ["tag", "-a", "v2", "v1", "-m", "tag of a tag"]);
		run(work, ["checkout", "-q", "main"]);

		// The remote has main, and a branch and pull-request ref work lacks.
		const r = new Stream();
		const rm0 = r.commit("refs/heads/main", "base", [
			["README.md", "hello\n"],
			["sub/x.txt", "x\n"],
		]);
		r.commit("refs/heads/ahead", "ahead", [], rm0);
		r.commit("refs/pull/1/head", "pr", [], rm0);
		fastImport(remote, r);
	});

	const texts = (tip: string, exclude: string[] = [`^${sha("main")}`], refs: string[] = []) =>
		collect(git, [tip], refs, exclude);
	const diffOf = (rev: string, t: Map<string, string>) => t.get(`diff-${sha(rev)}`) ?? "";

	test("collects each commit's raw object, with headers and message, below the tip too", () => {
		const t = texts("below");
		expect([...t.keys()].sort()).toEqual(
			["commit", "diff", "paths"].flatMap((k) => [`${k}-${sha("below")}`, `${k}-${sha("below~1")}`]).sort(),
		);
		expect(t.get(`commit-${sha("below~1")}`)).toContain("author t <t@t.t>");
		expect(t.get(`commit-${sha("below~1")}`)).toContain("\nsee acme-internal docs");
		expect(t.get(`paths-${sha("below")}`)).toBe("b.txt\n");
	});

	test("collects lines added and removed again within the push, binary ones too", () => {
		expect(diffOf("readded~1", texts("readded"))).toBe("see acme-internal docs\n");
		expect(diffOf("binary~1", texts("binary"))).toContain("see acme-internal docs\n");
	});

	test("collects a root commit's lines and a new empty file's path", () => {
		expect(diffOf("root~1", texts("root", []))).toBe("acme-internal\n");
		expect(texts("empty-file").get(`paths-${sha("empty-file")}`)).toBe("acme-internal-notes.md\n");
	});

	test("leaves out what already-public history has", () => {
		const t = texts("public", [`^${sha("public~2")}`]);
		expect([...t.values()].join("")).not.toContain("acme-internal");
	});

	test("collects a merge's own resolution, but not a line it keeps from one parent", () => {
		expect(diffOf("merge-adds~1", texts("merge-adds"))).toBe("c, see acme-internal docs\n");
		// The parent that has the line is already public.
		const keeps = texts("merge-keeps", [`^${sha("merge-keeps^1")}`]);
		expect(keeps.size).toBe(6);
		expect([...keeps.values()].join("")).not.toContain("acme-internal");
	});

	test("reads each binary file a merge resolves whole, apart, and under a non-ASCII name", () => {
		const added = diffOf("merge-binary~1", texts("merge-binary"));
		expect(added).toContain("see acme-internal docs\n");
		expect(added).toContain("\xff\x00acme-\n");
		expect(added).not.toContain("acme-internal\xff");
	});

	test("refuses a merge's binary file whose path git quotes, but not one the merge deletes", () => {
		expect(() => texts("merge-quoted")).toThrow(Refusal);
		expect(() => texts("merge-quoted")).toThrow("cannot read binary file");
		expect(diffOf("merge-deletes", texts("merge-deletes"))).toBe("");
	});

	// pack-objects sends the original object, not a local replacement.
	test("is not fooled by a replace ref", () => {
		expect(diffOf("replaced~1", texts("replaced"))).toBe("see acme-internal docs\n");
	});

	test("collects each annotated tag a tip names, through a tag of a tag", () => {
		const t = texts("v2", [], ["refs/tags/v2"]);
		expect(t.get(`tag-${sha("v1")}`)).toContain("release for acme-internal");
		expect(t.get(`tag-${sha("v2")}`)).toContain("tag of a tag");
		expect(t.get("ref-names")).toBe("refs/tags/v2\nv2\n");
	});

	test("asks the remote what it has, and whether it is ahead", () => {
		expect(askRemote(git, remote)).toEqual({ have: [`^${sha("main")}`], ahead: true });
		const r = run(["--remote", join(base, "missing.git"), "main"]);
		expect(r.status).toBe(1);
		// git's own error comes first.
		expect(r.err).toMatch(/^fatal: .*\nno-private-refs: cannot ask the remote what it already has — refusing the push\.\n$/s);
	});

	const run = (args: string[], cwd = work, gitEnv = env) => {
		let out = "";
		let err = "";
		const status = main(
			args,
			new Git(cwd, gitEnv),
			(s) => {
				out += s;
			},
			(s) => {
				err += s;
			},
		);
		return { status, out, err };
	};

	test("refuses a push of a private reference, naming the commit, and says to fetch while the remote is ahead", () => {
		const r = run(["--remote", remote, "--ref", "refs/heads/feature", "below"]);
		expect(r.status).toBe(1);
		expect(r.err).toContain(`ERROR: private pattern on line 3 of .git/info/private-refs in a commit, tag or ref name being pushed:\n    commit-${sha("below~1")}:`);
		expect(r.err).toContain("Run `git fetch` and push again first.");
	});

	test("refuses a private reference in a tracked file, binary or read in a UTF-8 locale", () => {
		expect(run(["tracked-binary"]).err).toContain("in a tracked file");
		const utf8 = scan(git, locale, new Map(), ["tracked-utf8"], [], [{ line: 1, regex: "acmeä?corp" }], FILE);
		expect(utf8).toEqual([
			{ label: `private pattern on line 1 of ${FILE}`, where: "tree", hits: [`tracked-utf8:a.txt:1:acmecorp`] },
		]);
	});

	test("lets allowed addresses through, with colour forced on in git config", () => {
		const colour = { ...env, GIT_CONFIG_PARAMETERS: "'color.ui'='always'" };
		expect(run(["--remote", remote, "emails"], work, colour)).toEqual({ status: 0, out: "", err: "" });
	});

	test("run by hand, skips history on a remote-tracking branch, and searches the whole tree from a subdirectory", () => {
		expect(run(["public"]).status).toBe(0);
		const r = run(["below"], join(work, "sub"));
		expect(r.status).toBe(1);
		expect(r.err).toContain("in a commit, tag or ref name being pushed");
		expect(run(["tracked-binary"], join(work, "sub")).err).toContain("in a tracked file");
	});

	test("refuses the push when the private-refs file is missing", () => {
		const r = run(["HEAD"], remote);
		expect(r.status).toBe(1);
		expect(r.err).toContain("./info/private-refs is missing or not a readable file");
	});

	test("--self-test reports the patterns it passed", () => {
		expect(run(["--self-test"])).toEqual({
			status: 0,
			out: "no-private-refs: 3 generic and 1 private patterns pass.\n",
			err: "",
		});
	});
});

// Pre-push check: refuse to push private references to this public repo.
//
//   bun scripts/no-private-refs.ts [--remote <url>] [--ref <name> <tip>]... [<tip>...]
//   bun scripts/no-private-refs.ts --self-test
//
// Everything pushed here is world-visible and effectively permanent: a
// squashed branch still leaves the commits a merged PR references, and
// editing a PR body leaves the old text in GitHub's edit history. So the
// only place to catch a private reference is before it leaves the machine.
//
// Two sets of patterns:
//
//   - Generic ones, defined below: Claude Code session URLs (injected into
//     commit trailers and PR descriptions by the harness unless
//     `attribution.sessionUrl` is false), local absolute paths, and email
//     addresses.
//   - Private ones, read from `info/private-refs` in the git common dir
//     (`.git/info/private-refs` in a plain clone). That file is never
//     tracked, so it holds names that would themselves leak if written here.
//     One extended regex per line; blank lines and lines starting with `#`
//     are skipped. Without the file the push and `--self-test` are refused;
//     create it empty if there is nothing private to guard.
//
// Checks everything the push publishes: the commits (headers, messages, and
// the lines and paths they add), annotated tags, the names of the refs
// pushed to, and the tree at each tip. A false positive is fixed by
// narrowing the pattern that matched or, for an address that is public by
// design, adding it to ALLOWED.
//
// Every scan uses git grep's extended regexes, which read escapes like `\b`
// and `\d` as plain letters. `--self-test` checks every generic pattern
// against a string it must match and one it must not, and every private
// pattern for errors and for some text that would make it silently miss what
// it is meant to match. Run it after editing a pattern.
//
// The logic is in the exported functions, which bun tests drive on literal
// inputs; only `collect` and the searches run git.

import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

export type Pattern = { label: string; regex: string; match: string; miss: string };

// git grep's ERE has no `\b`, so a pattern here or in the private file that
// needs a word boundary spells it out as a character class. Keep private
// patterns anchored enough to avoid ordinary prose: a bare fragment of a
// name would fire on almost anything.
//
// This file is itself tracked and scanned, so the examples are split where a
// contiguous one would match its own pattern.
//
// Each domain label of an email address starts with a letter or digit, as a
// hostname's must, so stray bytes in a binary file such as `r@-2.kt` are not
// read as one.
export const PATTERNS: Pattern[] = [
	{
		label: "Claude Code session URL",
		regex: "claude\\.ai/code/session",
		match: "see https://claude.ai/code/" + "session_01AB",
		miss: "see claude.ai/code/artifact/1",
	},
	{
		label: "local absolute path",
		regex: "/Users/[A-Za-z0-9_-]|~/\\.claude/[A-Za-z0-9_-]",
		match: "ran /Users/" + "a/oss/meerkat",
		miss: "paths (`/Users/…`)",
	},
	{
		label: "email address",
		regex: "[A-Za-z0-9._%+-]+@[A-Za-z0-9][A-Za-z0-9-]*(\\.[A-Za-z0-9][A-Za-z0-9-]*)*\\.[A-Za-z]{2,}",
		match: "mail a.dev@" + "corp.io now",
		miss: "mail someone@example.com now",
	},
];

// Generic-pattern matches that are public by design, in any case:
// placeholder domains and the no-reply addresses of commit trailers and
// GitHub's own commits. Applied to each hit on its own, after the `:` that
// precedes the match in git grep's `-o` output. Private patterns never go
// through it, so a private match is reported even when it ends in one of
// these addresses.
export const ALLOWED =
	/:([a-z0-9._%+-]+@example\.(com|org|net)|noreply@anthropic\.com|noreply@github\.com|[a-z0-9._%+-]+@users\.noreply\.github\.com)$/i;

// Refuses the push, with what a failed command printed to stderr, if any.
export class Refusal extends Error {
	constructor(
		message: string,
		readonly stderr = "",
	) {
		super(message);
	}
}

// Pushed content need not be valid text, so what git prints, and so each
// text collected and each hit, is held as bytes: a string with one byte per
// character (latin1). Patterns, paths, git's arguments and messages are
// ordinary strings, and `display` turns bytes into one.
const bytes = (s: string) => Buffer.from(s, "latin1");
const text = (b: Buffer | Uint8Array) => Buffer.from(b).toString("latin1");
export const display = (s: string) => bytes(s).toString("utf8");

export const dropAllowed = (hits: string[]) => hits.filter((hit) => !ALLOWED.test(hit));

export type PrivatePattern = { line: number; regex: string };

// Each pattern with the line of the file it came from. A CRLF line ending
// and a UTF-8 byte-order mark are dropped: kept, they would be part of the
// pattern.
export function parsePrivate(content: string): PrivatePattern[] {
	const lines = content.split("\n");
	if (lines.at(-1) === "") lines.pop();
	const patterns: PrivatePattern[] = [];
	lines.forEach((raw, i) => {
		let line = raw.endsWith("\r") ? raw.slice(0, -1) : raw;
		if (i === 0 && line.startsWith("﻿")) line = line.slice(1);
		if (line === "" || line.startsWith("#")) return;
		patterns.push({ line: i + 1, regex: line });
	});
	return patterns;
}

// Private patterns have no examples, so they are checked only for what would
// break them, before `validRegex`: text that makes one silently miss what it
// is meant to match. An escaped backslash is a literal one, so it is no
// escape here.
export function lintPrivate(regex: string): string | undefined {
	if (/\\[A-Za-z0-9<>]/.test(regex.replaceAll("\\\\", "")))
		return "has a backslash escape such as \\b, \\d, \\s or \\<, which git grep's ERE reads as a plain character; use a bracket class such as [0-9] or [[:space:]]";
	if ([...regex].some((c) => c < " " || c === "\x7f")) return "contains a control character, such as a tab or carriage return";
	if (/^[ \t\n\v\f\r]|[ \t\n\v\f\r]$/.test(regex))
		return "starts or ends with whitespace; write [ ] where a space is meant";
	return undefined;
}

// The outcome of one search: its hits, or 1 when nothing matched, 2 when git
// grep failed, and 3 when it matched empty text, since `-o` prints no empty
// match and skips the rest of its line, so the matches of a pattern that can
// match empty text are lost.
export type Search = { status: 0 | 1 | 2 | 3; hits: string[]; err: string };

// One git grep pass, from its exit status and output.
export function pass(status: number, out: string, err: string): Search {
	const hits = out.split("\n").filter((l) => l !== "");
	if (status === 0 && hits.length === 0) return { status: 3, hits, err };
	if (status === 0 || status === 1) return { status, hits, err };
	return { status: 2, hits, err };
}

// Each search runs once under the C locale and once in a UTF-8 one: under C,
// `.` and bracket expressions see a multibyte character's bytes one at a
// time, while under UTF-8 they can fail to match on a line with invalid
// bytes. The hits of either pass are reported.
export function combine(c: Search, u: Search): Search {
	const err = c.err + u.err;
	if (c.status === 2 || u.status === 2) return { status: 2, hits: [], err };
	if (c.status === 3 || u.status === 3) return { status: 3, hits: [], err };
	if (c.status === 1 && u.status === 1) return { status: 1, hits: [], err };
	return { status: 0, hits: [...new Set([...c.hits, ...u.hits])].sort(), err };
}

// The bytes of a UTF-8 text with each byte that is not part of a valid
// character dropped, for the UTF-8 pass. Newlines always stay, so a hit's
// line number is the same in both passes.
export function dropInvalidUtf8(input: Buffer): Buffer {
	const out = Buffer.alloc(input.length);
	let n = 0;
	let i = 0;
	while (i < input.length) {
		const b = input[i];
		let len = 0;
		let min = 0;
		if (b < 0x80) len = 1;
		else if (b >= 0xc2 && b <= 0xdf) [len, min] = [2, 0x80];
		else if (b >= 0xe0 && b <= 0xef) [len, min] = [3, 0x800];
		else if (b >= 0xf0 && b <= 0xf4) [len, min] = [4, 0x10000];
		let ok = len > 0 && i + len <= input.length;
		let cp = len === 1 ? b : b & (0xff >> (len + 1));
		for (let k = 1; ok && k < len; k++) {
			const c = input[i + k];
			if ((c & 0xc0) !== 0x80) ok = false;
			cp = (cp << 6) | (c & 0x3f);
		}
		if (ok && len > 1 && (cp < min || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff))) ok = false;
		if (ok) {
			input.copy(out, n, i, i + len);
			n += len;
			i += len;
		} else i += 1;
	}
	return out.subarray(0, n);
}

// The lines a commit adds, from its `git diff-tree --cc` output: anything a
// parent has is already public or checked as part of that parent. Each diff
// line starts with one marker column per parent, one for a root commit, and
// a line no parent has is `+` in every column. The markers are stripped so
// they are not read as part of a match. Each file's header runs from its
// `diff` line to its first hunk.
export function addedLines(diff: string, parents: number): string {
	const marker = "+".repeat(Math.max(parents, 1));
	let header = false;
	let out = "";
	for (const line of diff.split("\n")) {
		if (header) {
			if (line.startsWith("@@")) header = false;
		} else if (line.startsWith("diff ")) header = true;
		else if (line.startsWith(marker)) out += `${line.slice(marker.length)}\n`;
	}
	return out;
}

// The paths of the binary files a merge's `--cc` diff names: it prints only
// "Binary files differ" for one, even with `--text`, so each is read whole.
// Git quotes a path that has special characters, which cannot be read back.
export function mergeBinaryPaths(diff: string, sha: string): string[] {
	const paths: string[] = [];
	let path = "";
	for (const line of diff.split("\n")) {
		if (line.startsWith("diff --cc ")) path = line.slice("diff --cc ".length);
		else if (line.startsWith("Binary files")) {
			if (path.startsWith('"'))
				throw new Refusal(`cannot read binary file ${display(path)} in merge ${sha} — refusing the push.`);
			paths.push(display(path));
		}
	}
	return paths;
}

// Each ref name both in full and without its `refs/<kind>/` prefix, so a
// pattern anchored at the start can match the short name.
export const refNameLines = (refs: string[]) =>
	refs.map((ref) => `${ref}\n${ref.replace(/^refs\/[^/]*\//, "")}\n`).join("");

// From `git ls-remote` output and `git cat-file --batch-check` output for
// its OIDs, in the same order: the objects the remote has that this clone
// has too, which `rev-list` excludes, and whether a remote branch or tag tip
// this clone lacks hides what is below it, so that history the remote
// already holds can be scanned as new until a fetch. Other refs, such as a
// host's pull-request refs, are not fetched, so a fetch would not help.
export function published(lsRemote: string, batchCheck: string) {
	const refs = lsRemote.split("\n").filter((l) => l !== "");
	const objects = batchCheck.split("\n").filter((l) => l !== "");
	const have = objects.filter((l) => !l.endsWith(" missing")).map((l) => `^${l.split(" ")[0]}`);
	const ahead = objects.some(
		(l, i) => l.endsWith(" missing") && /^refs\/(heads|tags)\//.test(refs[i]?.split("\t")[1] ?? ""),
	);
	return { have, ahead };
}

export type Args = { remote?: string; refs: string[]; tips: string[] };

// .lefthook/pre-push/pre-push.ts passes `--remote <url>` and, for each ref
// being pushed, `--ref <remote ref name>` and its local tip. Run by hand
// with no tips, it checks HEAD.
export function parseArgs(argv: string[]): Args {
	const args: Args = { refs: [], tips: [] };
	for (let i = 0; i < argv.length; i++) {
		if (argv[i] === "--remote") {
			args.remote = argv[++i] ?? "";
			if (args.remote === "") throw new Refusal("no remote to ask what it already has — refusing the push.");
		} else if (argv[i] === "--ref") {
			args.refs.push(argv[++i]);
			args.tips.push(argv[++i]);
		} else args.tips.push(argv[i]);
	}
	if (args.tips.length === 0) args.tips.push("HEAD");
	return args;
}

export type Finding = { label: string; where: "history" | "tree"; hits: string[] };

// What to print on stderr for a scan's findings, or nothing when it found
// none. A fetch can clear a match only in history the remote already holds.
export function report(findings: Finding[], remoteAhead: boolean, privateFile: string): string {
	if (findings.length === 0) return "";
	let out = "";
	for (const f of findings) {
		out +=
			f.where === "history"
				? `ERROR: ${f.label} in a commit, tag or ref name being pushed:\n`
				: `ERROR: ${f.label} in a tracked file:\n`;
		for (const hit of f.hits) out += `    ${display(hit)}\n`;
	}
	out += "\n";
	const historyHit = findings.some(
		(f) => f.where === "history" && f.hits.some((h) => /^(commit|diff|paths)-/.test(h)),
	);
	if (remoteAhead && historyHit)
		out +=
			"The remote has commits this clone lacks, so a match may be in history\n" +
			"it already holds. Run `git fetch` and push again first.\n";
	out +=
		"This repo is public. Rewrite what matched and push again.\n" +
		"If the match is a false positive, narrow the pattern in\n" +
		`scripts/no-private-refs.ts or ${privateFile} and push again;\n` +
		"for a generic email address that is public by design, add it\n" +
		"to ALLOWED instead.\n";
	return out;
}

// Runs git, and everything else here, in `cwd`. Commands here read what the
// push sends: replace refs would show them a different object from the one
// pack-objects sends.
export class Git {
	constructor(
		readonly cwd: string,
		readonly env: Record<string, string | undefined> = process.env,
	) {}

	run(args: string[], opts: { locale?: string; stdin?: string; cwd?: string } = {}) {
		const proc = Bun.spawnSync(["git", ...args], {
			cwd: opts.cwd ?? this.cwd,
			env: { ...this.env, LC_ALL: opts.locale ?? "C", GIT_NO_REPLACE_OBJECTS: "1" },
			stdin: opts.stdin === undefined ? "ignore" : bytes(opts.stdin),
			stdout: "pipe",
			stderr: "pipe",
		});
		return { status: proc.exitCode ?? 2, out: text(proc.stdout), err: text(proc.stderr) };
	}

	// The output of a git command that must succeed, or a refusal saying what
	// could not be done.
	read(args: string[], what: string, stdin?: string) {
		const r = this.run(args, { stdin });
		if (r.status !== 0) throw new Refusal(`${what} — refusing the push.`, display(r.err));
		return r.out;
	}
}

// A locale `locale -a` lists for the UTF-8 pass.
export function utf8Locale(): string {
	const out = Bun.spawnSync(["locale", "-a"], { stderr: "ignore" }).stdout.toString();
	const found = out.split("\n").find((l) => /^(c|en_us)\.utf-?8$/i.test(l));
	if (!found) throw new Refusal("no UTF-8 locale to search in — refusing the push.");
	return found;
}

// What the push publishes besides its tips' trees, one text per object so a
// hit names it: each raw commit object, with all its headers and its
// message, the lines and paths each commit adds, each annotated tag, and the
// ref names. Binary files are diffed as text, so their added content is read
// too. The commits are those `exclude` (`rev-list` arguments read from
// stdin) leaves out, or, with no `exclude`, the ones no remote-tracking
// branch has.
export function collect(git: Git, tips: string[], refs: string[], exclude?: string[]): Map<string, string> {
	const texts = new Map<string, string>();
	const list =
		exclude === undefined
			? git.read(["rev-list", ...tips, "--not", "--remotes"], "cannot list the commits being pushed")
			: git.read(["rev-list", "--stdin", ...tips], "cannot list the commits being pushed", exclude.join("\n"));
	for (const sha of list.split("\n").filter((l) => l !== "")) {
		const cannot = `cannot read commit ${sha}`;
		texts.set(`commit-${sha}`, git.read(["cat-file", "commit", sha], cannot));
		const raw = git.read(
			[
				"-c",
				"core.quotePath=false",
				"diff-tree",
				"--cc",
				"--text",
				"--no-textconv",
				"--no-ext-diff",
				"-r",
				"--root",
				"--no-color",
				"--no-commit-id",
				sha,
			],
			cannot,
		);
		const paths = git.read(
			["diff-tree", "--cc", "-r", "--root", "--name-only", "-z", "--diff-filter=ACR", "--no-commit-id", sha],
			cannot,
		);
		// rev-list, like diff-tree, sees a commit at a shallow boundary as a
		// root, which its raw `parent` headers would not.
		const parents = git.read(["rev-list", "--parents", "-n", "1", sha], cannot).trim().split(/\s+/).length - 1;
		let added = addedLines(raw, parents);
		if (parents > 1) {
			for (const path of mergeBinaryPaths(raw, sha)) {
				// A file the merge deletes adds nothing. A newline after each file
				// keeps two files' bytes from joining into one match.
				if (git.run(["cat-file", "-e", `${sha}:${path}`]).status !== 0) continue;
				added += `${git.read(["cat-file", "blob", `${sha}:${path}`], `cannot read ${path} in merge ${sha}`)}\n`;
			}
		}
		texts.set(`diff-${sha}`, added);
		texts.set(`paths-${sha}`, paths.replaceAll("\0", "\n"));
	}
	for (const tip of tips) {
		let object = tip;
		for (;;) {
			const type = git.read(["cat-file", "-t", object], `cannot read object ${object}`).trim();
			if (type !== "tag") break;
			const sha = git.read(["rev-parse", object], `cannot read tag ${object}`).trim();
			const tag = git.read(["cat-file", "tag", sha], `cannot read tag ${sha}`);
			texts.set(`tag-${sha}`, tag);
			// A tag's first line names the object it tags, which may be a tag.
			object = tag.match(/^object (\S+)/)?.[1] ?? "";
		}
	}
	if (refs.length > 0) texts.set("ref-names", refNameLines(refs));
	return texts;
}

// What the remote has is asked of the remote itself: tracking branches can
// be stale, and a new remote or a URL has none. Any of its objects this
// clone lacks cannot be in the push, so only the ones it has are excluded.
// A remote that cannot be asked refuses the push rather than letting a
// guess decide which commits count as public.
export function askRemote(git: Git, remote: string) {
	// The URL is not echoed, since it can hold credentials.
	const cannot = "cannot ask the remote what it already has";
	const lsRemote = git.read(["ls-remote", remote], cannot);
	const oids = lsRemote
		.split("\n")
		.filter((l) => l !== "")
		.map((l) => l.split("\t")[0]);
	// `--batch-check` prints `<sha> missing` for an object this clone lacks,
	// and GIT_NO_LAZY_FETCH stops a partial clone fetching each one.
	const check = new Git(git.cwd, { ...git.env, GIT_NO_LAZY_FETCH: "1" });
	const batch = check.read(["cat-file", "--batch-check"], cannot, oids.map((o) => `${o}\n`).join(""));
	return published(lsRemote, batch);
}

// Searches files with git grep in both locales. `dir` searches a directory,
// which need not be in a repo, and for the UTF-8 pass `utf8Dir`, a copy of
// it with invalid bytes dropped; from inside a repo, --no-index still
// refuses a pathspec outside it, so git starts in the directory. Otherwise
// it searches the whole trees of `tips`, from wherever git runs; `git grep
// <tips>` never reads the working tree.
export function search(
	git: Git,
	locale: string,
	regex: string,
	where: { dir: string; utf8Dir?: string } | { tips: string[] },
): Search {
	const one = (loc: string) => {
		const args = ["-c", "color.grep=never", "grep"];
		let cwd: string | undefined;
		if ("dir" in where) {
			cwd = loc === "C" ? where.dir : (where.utf8Dir ?? where.dir);
			args.push("--no-index", "--text", "-noE", "-e", regex, "--", ".");
		} else args.push("--text", "-noE", "-e", regex, ...where.tips, "--", ":/");
		const r = git.run(args, { locale: loc, cwd });
		return pass(r.status, r.out, r.err);
	};
	return combine(one("C"), one(locale));
}

// Writes `files`, whose contents are bytes, into a new temporary directory,
// for git grep to read, and returns it. The caller removes it.
export function writeDir(files: Map<string, string>): string {
	const dir = mkdtempSync(join(tmpdir(), "no-private-refs-"));
	for (const [name, content] of files) {
		mkdirSync(join(dir, name, ".."), { recursive: true });
		writeFileSync(join(dir, name), bytes(content));
	}
	return dir;
}

// Fails a pattern that git grep refuses, or one that matches an empty line;
// one that matches empty text only beside other text refuses the push when
// the scan meets it.
function validRegex(git: Git, locale: string, where: string, regex: string, empty: string): string | undefined {
	const r = search(git, locale, regex, { dir: empty });
	if (r.status === 0 || r.status === 3)
		return `SELF-TEST: ${where} matches empty text, so git grep cannot show its matches`;
	if (r.status > 1) return `SELF-TEST: ${where} is not a valid regex: ${display(r.err).trimEnd()}`;
	return undefined;
}

// Checks every pattern as the header describes, returning one line per
// failure. git grep reads files, never stdin, so the samples are files: an
// empty line in `empty/`, and in `examples/` each generic pattern's example
// as `match-<n>` and its counter-example as `miss-<n>`. Each generic pattern
// searches each directory once, and its hits are told apart by file.
export function selfTest(
	git: Git,
	locale: string,
	generic: Pattern[],
	priv: PrivatePattern[],
	privateFile: string,
): string[] {
	const samples = new Map<string, string>([["empty/sample.txt", "\n"]]);
	const utf8 = (s: string) => text(Buffer.from(s, "utf8"));
	generic.forEach((p, i) => {
		samples.set(`examples/match-${i}`, utf8(`${p.match}\n`));
		samples.set(`examples/miss-${i}`, utf8(`${p.miss}\n`));
	});
	const dir = writeDir(samples);
	const empty = join(dir, "empty");
	const failures: string[] = [];
	try {
		for (const [i, p] of generic.entries()) {
			const invalid = validRegex(git, locale, `'${p.label}'`, p.regex, empty);
			if (invalid) {
				failures.push(invalid);
				continue;
			}
			const hits = search(git, locale, p.regex, { dir: join(dir, "examples") }).hits;
			const reports = (file: string) => dropAllowed(hits.filter((h) => h.startsWith(`${file}:`))).length > 0;
			if (!reports(`match-${i}`)) failures.push(`SELF-TEST: '${p.label}' misses its own example: ${p.match}`);
			if (reports(`miss-${i}`)) failures.push(`SELF-TEST: '${p.label}' fires on its counter-example: ${p.miss}`);
		}
		for (const p of priv) {
			const where = `line ${p.line} of ${privateFile}`;
			const lint = lintPrivate(p.regex);
			const failure = lint ? `SELF-TEST: ${where} ${lint}` : validRegex(git, locale, where, p.regex, empty);
			if (failure) failures.push(failure);
		}
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
	return failures;
}

// Scans `texts`, and the trees of `tips` when there are any, for every
// pattern, returning what matched. A search that fails refuses the push.
export function scan(
	git: Git,
	locale: string,
	texts: Map<string, string>,
	tips: string[],
	generic: Pattern[],
	priv: PrivatePattern[],
	privateFile: string,
): Finding[] {
	const utf8 = new Map([...texts].map(([name, content]) => [name, text(dropInvalidUtf8(bytes(content)))]));
	const dir = writeDir(texts);
	const utf8Dir = writeDir(utf8);
	const findings: Finding[] = [];
	const checked = (r: Search, label: string, what: string) => {
		if (r.status === 3)
			throw new Refusal(
				`${label} matches empty text in ${what}, so git grep cannot show its matches — refusing the push.`,
			);
		if (r.status === 2) throw new Refusal(`cannot search ${what} — refusing the push.`);
		return r.hits;
	};
	const each = (label: string, regex: string, generic: boolean) => {
		const filter = generic ? dropAllowed : (hits: string[]) => hits;
		const history = filter(
			checked(
				search(git, locale, regex, { dir, utf8Dir }),
				label,
				"the commits, tags and ref names being pushed",
			),
		);
		if (history.length > 0) findings.push({ label, where: "history", hits: history });
		if (tips.length === 0) return;
		const tree = filter(checked(search(git, locale, regex, { tips }), label, "the files being pushed"));
		if (tree.length > 0) findings.push({ label, where: "tree", hits: tree });
	};
	try {
		for (const p of generic) each(p.label, p.regex, true);
		for (const p of priv) each(`private pattern on line ${p.line} of ${privateFile}`, p.regex, false);
	} finally {
		rmSync(dir, { recursive: true, force: true });
		rmSync(utf8Dir, { recursive: true, force: true });
	}
	return findings;
}

// The private-refs file's path, as git names the common dir, and its
// patterns, or a refusal when it is missing or unreadable.
export function loadPrivate(git: Git): { file: string; patterns: PrivatePattern[] } {
	const commonDir = display(git.read(["rev-parse", "--git-common-dir"], "cannot find the git common dir").trim());
	const file = `${commonDir}/info/private-refs`;
	let content: string;
	try {
		const path = resolve(git.cwd, file);
		if (!statSync(path).isFile()) throw new Error();
		content = readFileSync(path, "utf8");
	} catch {
		throw new Refusal(
			`${file} is missing or not a readable file — refusing the push.\n` +
				"It lists this machine's private patterns, one extended regex per line.\n" +
				"Create it, empty if there is nothing private to guard, and push again.",
		);
	}
	return { file, patterns: parsePrivate(content) };
}

// The whole check, as run from the command line, writing to `out` and `err`
// and returning the exit status.
export function main(argv: string[], git: Git, out: (s: string) => void, err: (s: string) => void): number {
	try {
		const locale = utf8Locale();
		const priv = loadPrivate(git);
		const failures = selfTest(git, locale, PATTERNS, priv.patterns, priv.file);
		if (argv[0] === "--self-test") {
			for (const f of failures) err(`${f}\n`);
			if (failures.length > 0) return 1;
			out(`no-private-refs: ${PATTERNS.length} generic and ${priv.patterns.length} private patterns pass.\n`);
			return 0;
		}
		// A pattern that matches nothing lets every push through while looking
		// like a check, so the patterns are proved before they are trusted.
		if (failures.length > 0) {
			for (const f of failures) err(`${f}\n`);
			throw new Refusal("a pattern is broken — refusing the push.");
		}
		const args = parseArgs(argv);
		const remote = args.remote === undefined ? undefined : askRemote(git, args.remote);
		const texts = collect(git, args.tips, args.refs, remote?.have);
		const findings = scan(git, locale, texts, args.tips, PATTERNS, priv.patterns, priv.file);
		err(report(findings, remote?.ahead ?? false, priv.file));
		return findings.length > 0 ? 1 : 0;
	} catch (e) {
		if (!(e instanceof Refusal)) throw e;
		err(`${e.stderr}no-private-refs: ${e.message}\n`);
		return 1;
	}
}

if (import.meta.main) {
	const write = (fd: number) => (s: string) => writeFileSync(fd, s);
	process.exit(main(process.argv.slice(2), new Git(process.cwd()), write(1), write(2)));
}

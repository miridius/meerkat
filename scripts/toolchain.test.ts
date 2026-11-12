// Drives scripts/toolchain.ts's main through a stand-in Io: the web is a
// map of URL to body, the files a map of path to text. The ExUnit test
// test/scripts/toolchain_test.exs covers the seams this leaves out: curl,
// pnpm and the files on disk.
import { createHash } from "node:crypto";
import { beforeEach, describe, expect, test } from "bun:test";
import { affects, compare, type Io, inRange, main, target, Unreadable } from "./toolchain";

const NOW = Date.parse("2026-11-12T12:00:00Z");
const OLD = "2020-01-01T00:00:00Z";
const hoursAgo = (h: number) => new Date(NOW - h * 3_600_000).toISOString();

const TOOL_VERSIONS = "erlang 29.1.2\nelixir 1.20.4\nbun 1.4.3\n";
const ENV = `# pins
HEX_VERSION=2.5.3
REBAR3_VERSION=3.27.3
REBAR3_SHA256=aaa
CLJ_KONDO_VERSION=2026.08.04
CLJ_KONDO_SHA256=bbb
PLANTUML_VERSION=1.2026.8
PLANTUML_SHA256=ccc
GNU_BASH_VERSION=5.3.2
GNU_BASH_SHA256=ddd
GRAPHVIZ_VERSION=16.1.0
GRAPHVIZ_SHA256=eee
`;
const CHECKOUT = "a".repeat(40);
const CHECKOUT_NEXT = "b".repeat(40);
const WORKFLOWS = {
	".github/workflows/ci.yml": `jobs:\n  test:\n    steps:\n      - uses: actions/checkout@${CHECKOUT} # v7.0.1\n      - uses: ./.github/actions/local\n`,
	".github/workflows/audit.yml": `jobs:\n  audit:\n    steps:\n      - uses: actions/checkout@${CHECKOUT} # v7.0.1\n`,
	".github/actions/toolchain/action.yml": `runs:\n  using: composite\n  steps:\n    - uses: actions/checkout@${CHECKOUT} # v7.0.1\n`,
};

// A body, or one per read of its URL, counted from 1.
type Body = string | ((read: number) => string);

let web: Map<string, Body>;
let heads: Map<string, string>;
let reads: Map<string, number>;
let files: Map<string, string>;
let relocks: number;

const io: Io = {
	fetch: async (url, opts = {}) => {
		const n = (reads.get(url) ?? 0) + 1;
		reads.set(url, n);
		const body = opts.head ? heads.get(url) : web.get(url);
		const served = typeof body === "function" ? body(n) : body;
		if (served !== undefined) return new TextEncoder().encode(served);
		if (url.startsWith("https://api.github.com/")) return new TextEncoder().encode("[]");
		throw new Unreadable(`${url}: curl: (22) 404`);
	},
	read: (path) => {
		const text = files.get(path);
		if (text === undefined) throw new Error(`ENOENT ${path}`);
		return text;
	},
	write: (path, body) => {
		files.set(path, body);
	},
	relockPnpm: () => {
		relocks++;
	},
	now: NOW,
	log: (line) => out.push(line),
	error: (line) => out.push(line),
};
let out: string[];

async function toolchain(mode: string): Promise<{ code: number; out: string }> {
	out = [];
	const code = await main(mode, { ...io });
	return { code, out: out.map((line) => `${line}\n`).join("") };
}

// ------------------------------------------------------------- fixtures

const sha256 = (text: string) => createHash("sha256").update(text).digest("hex");

const serve = (url: string, body: Body) => web.set(url, body);

type Rel = [tag: string, at: string, pre?: boolean];
const releasesJson = (releases: Rel[]) =>
	JSON.stringify(
		releases.map(([tag, at, pre = false]) => ({ tag_name: tag, published_at: at, draft: false, prerelease: pre })),
	);
const github = (repo: string, releases: Rel[]) =>
	serve(`https://api.github.com/repos/${repo}/releases?per_page=100`, releasesJson(releases));
const commit = (repo: string, tag: string, sha: string) =>
	serve(`https://api.github.com/repos/${repo}/commits/${tag}`, JSON.stringify({ sha }));

// OTP RELEASES on GitHub, each built for both runners, or for Ubuntu only
// those UBUNTU lists. Each build is dated now, as a rebuild would.
function otp(releases: [string, string][], ubuntu?: string[]) {
	const versions = releases.map(([v]) => v);
	github(
		"erlang/otp",
		releases.map(([v, at]) => [`OTP-${v}`, at]),
	);
	serve(
		"https://raw.githubusercontent.com/erlef/otp_builds/refs/heads/main/builds/aarch64-apple-darwin.csv",
		`ref_name,ref,datetime,sha256\nmaster,abc,${OLD},def\n${versions.map((v) => `OTP-${v},abc,${hoursAgo(0)},def\n`).join("")}`,
	);
	serve(
		"https://builds.hex.pm/builds/otp/ubuntu-24.04/builds.txt",
		(ubuntu ?? versions).map((v) => `OTP-${v} abc ${hoursAgo(0)} def\n`).join(""),
	);
}

// Elixir BUILDS, "version-otp-major", each released on GitHub at its date
// and built now, as a rebuild would.
function elixir(builds: [string, string][]) {
	const released = new Map(builds.map(([b, at]) => [`v${b.split("-otp-")[0]}`, at]));
	github("elixir-lang/elixir", [...released].map(([tag, at]) => [tag, at]));
	serve(
		"https://builds.hex.pm/builds/elixir/builds.txt",
		builds.map(([b]) => `v${b} abc ${hoursAgo(0)} def \n`).join(""),
	);
}

const lastModified = (at: string) => `HTTP/2 200\r\nlast-modified: ${new Date(at).toUTCString()}\r\n\r\n`;

// Lists bash BASE and its PATCHES, each patch's file dated by its
// Last-Modified. With UNPATCHED, also lists that newer version, released
// AT with no patches directory yet.
function bash(base: string, patches: [number, string][], unpatched?: [string, string]) {
	const [major, minor] = base.split(".");
	const file = (n: number) => `bash${major}${minor}-${String(n).padStart(3, "0")}`;
	let newer = "";
	if (unpatched) {
		heads.set(`https://ftp.gnu.org/gnu/bash/bash-${unpatched[0]}.tar.gz`, lastModified(unpatched[1]));
		newer = `<a href="bash-${unpatched[0]}.tar.gz">x</a>`;
	}
	serve(
		"https://ftp.gnu.org/gnu/bash/",
		`<a href="bash-5.2.tar.gz">x</a><a href="bash-${base}.tar.gz">x</a>` +
			`<a href="bash-${base}-patches/">x</a><a href="bash-6.0-rc1.tar.gz">x</a>${newer}`,
	);
	serve(
		`https://ftp.gnu.org/gnu/bash/bash-${base}-patches/`,
		patches.map(([n]) => `<a href="${file(n)}">x</a>`).join(""),
	);
	for (const [n, at] of patches)
		heads.set(`https://ftp.gnu.org/gnu/bash/bash-${base}-patches/${file(n)}`, lastModified(at));
}

const graphviz = (releases: [string, string][]) =>
	serve(
		"https://gitlab.com/api/v4/projects/4207231/releases?per_page=100",
		JSON.stringify(releases.map(([tag, at]) => ({ tag_name: tag, released_at: at, upcoming_release: false }))),
	);

const npmPnpm = (latest: string, time: Record<string, string>) =>
	serve("https://registry.npmjs.org/pnpm", JSON.stringify({ "dist-tags": { latest }, time }));

// One advisory, with a row for each of ROWS: a range, or a range with its
// patched versions.
type Row = string | [range: string, patched: string];
const advisoryJson = (name: string, rows: Row[], withdrawn?: string) => ({
	withdrawn_at: withdrawn ?? null,
	vulnerabilities: rows.map((row) => {
		const [range, patched] = typeof row === "string" ? [row, null] : row;
		return { package: { name }, vulnerable_version_range: range, patched_versions: patched };
	}),
});
const repoAdvisory = (repo: string, name: string, rows: Row | Row[], withdrawn?: string) =>
	serve(
		`https://api.github.com/repos/${repo}/security-advisories?state=published&per_page=100`,
		JSON.stringify([advisoryJson(name, [rows].flat(), withdrawn)]),
	);
const otpAdvisories = (advisories: [string, string][][]) =>
	serve(
		"https://api.github.com/repos/erlang/otp/security-advisories?state=published&per_page=100",
		JSON.stringify(advisories.map((rows) => advisoryJson("OTP", rows))),
	);
const globalAdvisory = (ecosystem: string, name: string, range: string) =>
	serve(
		`https://api.github.com/advisories?ecosystem=${ecosystem}&affects=${encodeURIComponent(name)}&per_page=100`,
		JSON.stringify([{ vulnerabilities: [{ package: { name }, vulnerable_version_range: range }] }]),
	);

const tools = () => files.get(".tool-versions");
const env = () => files.get(".github/toolchain.env");
const pinBun = (version: string) =>
	files.set(".tool-versions", (tools() as string).replace(/bun \S+/, `bun ${version}`));

const BUN_RELEASES = "https://api.github.com/repos/oven-sh/bun/releases?per_page=100";

// Every pin is the newest release, published long ago.
beforeEach(() => {
	web = new Map();
	heads = new Map();
	reads = new Map();
	relocks = 0;
	files = new Map([
		[".tool-versions", TOOL_VERSIONS],
		[".github/toolchain.env", ENV],
		["package.json", '{\n  "name": "x",\n  "packageManager": "pnpm@12.11.2"\n}\n'],
		...Object.entries(WORKFLOWS),
	]);
	github("oven-sh/bun", [["bun-v1.4.3", OLD]]);
	otp([["29.1.2", OLD]]);
	elixir([["1.20.4-otp-29", OLD]]);
	github("hexpm/hex", [["v2.5.3", OLD]]);
	github("erlang/rebar3", [["3.27.3", OLD]]);
	github("clj-kondo/clj-kondo", [["v2026.08.04", OLD]]);
	github("plantuml/plantuml", [
		["v1.2026.8", OLD],
		["snapshot", OLD, true],
	]);
	bash("5.3", [
		[1, OLD],
		[2, OLD],
	]);
	graphviz([
		["16.1.0", OLD],
		["16.0.0", OLD],
	]);
	npmPnpm("12.11.2", { created: OLD, "12.11.2": OLD, "12.14.0": OLD });
	github("actions/checkout", [["v7.0.1", OLD]]);
	commit("actions/checkout", "v7.0.1", CHECKOUT);
});

// ---------------------------------------------------------------- tests

test("pins on their targets pass the check", async () => {
	const { code, out } = await toolchain("check");
	expect(code).toBe(0);
	for (const pin of [
		"Erlang/OTP 29.1.2",
		"Elixir 1.20.4",
		"bun 1.4.3",
		"Hex 2.5.3",
		"rebar3 3.27.3",
		"clj-kondo 2026.08.04",
		"PlantUML 1.2026.8",
		"GNU bash 5.3.2",
		"Graphviz 16.1.0",
		// pnpm's next-12 release is not past its latest dist-tag.
		"pnpm 12.11.2",
		"actions/checkout v7.0.1",
	])
		expect(out).toContain(`current: ${pin}\n`);
});

describe("a newer release", () => {
	test("at least 24h old is the target", async () => {
		github("oven-sh/bun", [
			["bun-v1.4.3", OLD],
			["bun-v1.4.10", hoursAgo(25)],
		]);
		expect(await toolchain("check")).toMatchObject({ code: 1 });
		expect(out.join("\n")).toContain("BLOCKED: bun is pinned to 1.4.3; the target is 1.4.10");

		const bump = await toolchain("bump");
		expect(bump).toEqual({ code: 0, out: "pre-commit: toolchain: bun 1.4.3 -> 1.4.10\n" });
		expect(tools()).toBe("erlang 29.1.2\nelixir 1.20.4\nbun 1.4.10\n");
		expect((await toolchain("check")).code).toBe(0);
	});

	test("under 24h old is not yet the target", async () => {
		github("oven-sh/bun", [
			["bun-v1.4.4", hoursAgo(23)],
			["bun-v1.4.3", OLD],
		]);
		elixir([
			["1.20.4-otp-29", OLD],
			["1.20.5-otp-29", hoursAgo(1)],
		]);
		bash("5.3", [
			[1, OLD],
			[2, OLD],
			[3, hoursAgo(2)],
		]);
		expect((await toolchain("check")).code).toBe(0);
	});

	test("of GNU bash under 24h old, not yet patched, leaves the previous version's target", async () => {
		bash(
			"5.3",
			[
				[1, OLD],
				[2, OLD],
			],
			["5.4", hoursAgo(2)],
		);
		const { code, out } = await toolchain("check");
		expect(code).toBe(0);
		expect(out).toContain("current: GNU bash 5.3.2");
	});

	test("of GNU bash 24h old, not yet patched, becomes the target", async () => {
		bash(
			"5.3",
			[
				[1, OLD],
				[2, OLD],
			],
			["5.4", OLD],
		);
		const { code, out } = await toolchain("check");
		expect(code).toBe(1);
		expect(out).toContain("BLOCKED: GNU bash is pinned to 5.3.2; the target is 5.4.0");
	});

	test("in testing is never the target", async () => {
		github("erlang/rebar3", [
			["3.27.3", OLD],
			["3.28.0", OLD, true],
		]);
		elixir([
			["1.20.4-otp-29", OLD],
			["1.21.0-rc.0-otp-29", OLD],
		]);
		expect((await toolchain("check")).code).toBe(0);
	});
});

describe("an advisory on the newest release 24h old", () => {
	beforeEach(() =>
		github("oven-sh/bun", [
			["bun-v1.4.3", OLD],
			["bun-v1.4.4", hoursAgo(3)],
			["bun-v1.4.5", hoursAgo(1)],
		]),
	);

	test.each(["< 1.4.4", ">= 1.0, < 1.4.4", ">= 1.0.0 and < 1.4.4", "≥ 1.4.0-rc1 and < 1.4.4"])(
		"makes the lowest newer release it does not cover the target (%s)",
		async (range) => {
			repoAdvisory("oven-sh/bun", "bun", range);
			const { code, out } = await toolchain("check");
			expect(code).toBe(1);
			expect(out).toContain(
				"BLOCKED: bun is pinned to 1.4.3; the target is 1.4.4 (fixes an advisory on the newest release 24h old)",
			);
			expect((await toolchain("bump")).code).toBe(0);
			expect(tools()).toContain("\nbun 1.4.4\n");
		},
	);

	test("never moves a newer pin down to the fix", async () => {
		pinBun("1.4.5");
		repoAdvisory("oven-sh/bun", "bun", "= 1.4.3");
		const { code, out } = await toolchain("check");
		expect(code).toBe(0);
		expect(out).toContain("current: bun 1.4.5 (fixes an advisory");
	});

	test("for another package leaves the target alone", async () => {
		repoAdvisory("oven-sh/bun", "bunx", "< 1.4.4");
		expect((await toolchain("check")).code).toBe(0);
	});

	test("that is withdrawn leaves the target alone", async () => {
		repoAdvisory("oven-sh/bun", "bun", "< 1.4.4", "2026-01-01T00:00:00Z");
		expect((await toolchain("check")).code).toBe(0);
	});

	test.each<Row | Row[]>([
		">= 1.0",
		">= 0",
		[["< 0.9.0", ">= 0.9.0"]],
		[[">= 0.1", ">= 0.2"]],
		[[["= 0.5.0", "0.5.1"], ">= 0.6.0"]],
		[[[">= 0.5.0", "0.5.1"], ">= 1.0.0"]],
	])("with no release that fixes it leaves the target alone, noting the advisory (%j)", async (rows) => {
		repoAdvisory("oven-sh/bun", "bun", rows);
		const { code, out } = await toolchain("check");
		expect(code).toBe(0);
		expect(out).toContain("current: bun 1.4.3 (an advisory covers it; no release fixes it yet)");
	});
});

test("an unfixed advisory on the newest release 24h old keeps a pin it does not cover", async () => {
	github("oven-sh/bun", [
		["bun-v1.4.3", OLD],
		["bun-v1.4.4", OLD],
		["bun-v1.4.5", hoursAgo(1)],
	]);
	repoAdvisory("oven-sh/bun", "bun", ">= 1.4.4");
	const { code, out } = await toolchain("check");
	expect(code).toBe(0);
	expect(out).toContain(
		"current: bun 1.4.3 (an advisory covers the newest release 24h old; no release fixes it yet)",
	);
	expect((await toolchain("bump")).code).toBe(0);
	expect(tools()).toBe(TOOL_VERSIONS);
});

describe("an unfixed advisory on the newest release 24h old moves the pin there", () => {
	test("when it covers the pin too", async () => {
		pinBun("1.4.2");
		github("oven-sh/bun", [
			["bun-v1.4.2", OLD],
			["bun-v1.4.3", OLD],
		]);
		repoAdvisory("oven-sh/bun", "bun", ">= 1.0");
		const { code, out } = await toolchain("check");
		expect(code).toBe(1);
		expect(out).toContain(
			"BLOCKED: bun is pinned to 1.4.2; the target is 1.4.3 (an advisory covers it; no release fixes it yet)",
		);
	});

	test("unless a release 24h old newer than the pin is clean", async () => {
		pinBun("1.4.1");
		github("oven-sh/bun", [
			["bun-v1.4.1", OLD],
			["bun-v1.4.2", OLD],
			["bun-v1.4.3", OLD],
		]);
		repoAdvisory("oven-sh/bun", "bun", ">= 1.4.3");
		const { code, out } = await toolchain("check");
		expect(code).toBe(1);
		expect(out).toContain("BLOCKED: bun is pinned to 1.4.1; the target is 1.4.2 (an advisory covers the newest");
	});

	test("unless the pin is newer", async () => {
		pinBun("1.4.4");
		github("oven-sh/bun", [
			["bun-v1.4.3", OLD],
			["bun-v1.4.4", hoursAgo(2)],
		]);
		repoAdvisory("oven-sh/bun", "bun", [">= 1.4.0"]);
		const { code, out } = await toolchain("check");
		expect(code).toBe(0);
		expect(out).toContain("current: bun 1.4.4 (an advisory covers it; no release fixes it yet)");
	});

	test("when the pin is no longer a release", async () => {
		github("oven-sh/bun", [["bun-v1.4.4", OLD]]);
		repoAdvisory("oven-sh/bun", "bun", ">= 1.4.4");
		let { code, out } = await toolchain("check");
		expect(code).toBe(1);
		expect(out).toContain("BLOCKED: bun is pinned to 1.4.3; the target is 1.4.4");

		pinBun("1.4.5");
		repoAdvisory("oven-sh/bun", "bun", ">= 1.0");
		({ code, out } = await toolchain("check"));
		expect(code).toBe(1);
		expect(out).toContain("BLOCKED: bun is pinned to 1.4.5; the target is 1.4.4");
	});

	test("rather than to a clean release older than the pin", async () => {
		pinBun("1.4.2");
		github("oven-sh/bun", [
			["bun-v1.4.1", OLD],
			["bun-v1.4.2", OLD],
			["bun-v1.4.3", OLD],
		]);
		repoAdvisory("oven-sh/bun", "bun", ">= 1.4.2");
		const { code, out } = await toolchain("check");
		expect(code).toBe(1);
		expect(out).toContain("BLOCKED: bun is pinned to 1.4.2; the target is 1.4.3");
	});

	test("unless the pin is a clean release under 24h old", async () => {
		pinBun("1.3.9");
		github("oven-sh/bun", [
			["bun-v1.3.9", hoursAgo(2)],
			["bun-v1.4.3", OLD],
		]);
		repoAdvisory("oven-sh/bun", "bun", ">= 1.4.0");
		const { code, out } = await toolchain("check");
		expect(code).toBe(0);
		expect(out).toContain("current: bun 1.3.9 (an advisory covers the newest release 24h old");
	});

	test("unless a fix for the pin under 24h old is newer than it", async () => {
		pinBun("1.3.8");
		github("oven-sh/bun", [
			["bun-v1.3.8", OLD],
			["bun-v1.3.9", hoursAgo(2)],
			["bun-v1.4.2", OLD],
			["bun-v1.4.3", OLD],
		]);
		repoAdvisory("oven-sh/bun", "bun", [">= 1.4.0", "< 1.3.9"]);
		const { code, out } = await toolchain("check");
		expect(code).toBe(1);
		expect(out).toContain("BLOCKED: bun is pinned to 1.3.8; the target is 1.3.9 (fixes an advisory");
	});
});

// Erlang/OTP writes ranges with no upper bound, naming the fix on each
// release line in patched_versions.
describe("an Erlang/OTP advisory", () => {
	test("makes the young release that patches its line the target", async () => {
		otp([
			["29.1.2", OLD],
			["29.1.3", hoursAgo(2)],
			["29.2.0", hoursAgo(1)],
		]);
		otpAdvisories([
			[[">= 18.0", "29.1.3, 28.5.0.9, 27.3.4.20"]],
			[
				[">= 26.2.1", "26.2.5.12, 27.3.4"],
				[">= 24.3.4.15", ""],
			],
			[[">= 17.0", "23.2.3"]],
		]);
		const { code, out } = await toolchain("check");
		expect(code).toBe(1);
		expect(out).toContain("BLOCKED: Erlang/OTP is pinned to 29.1.2; the target is 29.1.3 (fixes an advisory");
		expect((await toolchain("bump")).code).toBe(0);
		expect(tools()).toContain("erlang 29.1.3\n");
		expect((await toolchain("check")).code).toBe(0);
	});

	test("passes a release its line's patch or a newer line covers", async () => {
		otp([
			["29.1.2", OLD],
			["29.1.3", hoursAgo(1)],
		]);
		otpAdvisories([
			[[">= 18.0", "29.1.2, 28.5.0.8"]],
			[
				[">= 26.2.1", "26.2.5.12, 27.3.4"],
				[">= 24.3.4.15", ""],
			],
			[[">= 17.0", "23.2.3"]],
		]);
		const { code, out } = await toolchain("check");
		expect(code).toBe(0);
		expect(out).toContain("current: Erlang/OTP 29.1.2\n");
	});

	test("with one open range and no patched version covers every newer line", async () => {
		otpAdvisories([[[">= 17.0", ""]]]);
		const { code, out } = await toolchain("check");
		expect(code).toBe(0);
		expect(out).toContain("current: Erlang/OTP 29.1.2 (an advisory covers it; no release fixes it yet)");
	});
});

describe("pnpm", () => {
	test("takes its advisories from GitHub's npm advisories", async () => {
		npmPnpm("12.11.3", { "12.11.2": OLD, "12.11.3": hoursAgo(2) });
		globalAdvisory("npm", "pnpm", "< 12.11.3");
		const { code, out } = await toolchain("bump");
		expect(code).toBe(0);
		expect(out).toContain("pnpm 12.11.2 -> 12.11.3 (fixes an advisory");
		expect(files.get("package.json")).toContain('"packageManager": "pnpm@12.11.3"');
		expect(relocks).toBe(1);
	});

	test("a bump rewrites packageManager and re-locks pnpm", async () => {
		npmPnpm("12.14.0", { "12.11.2": OLD, "12.14.0": OLD });
		expect((await toolchain("bump")).code).toBe(0);
		expect(files.get("package.json")).toBe('{\n  "name": "x",\n  "packageManager": "pnpm@12.14.0"\n}\n');
		expect(relocks).toBe(1);
	});

	test("with no publish times fails closed", async () => {
		serve("https://registry.npmjs.org/pnpm", "{}");
		const { code, out } = await toolchain("check");
		expect(code).toBe(2);
		expect(out).toContain("pnpm: npm lists no publish times");
	});
});

describe("a pin with a checksum", () => {
	test("gets the new release's checksum", async () => {
		github("erlang/rebar3", [
			["3.27.3", OLD],
			["3.27.4", OLD],
		]);
		serve("https://github.com/erlang/rebar3/releases/download/3.27.4/rebar3", "escript");
		expect((await toolchain("bump")).code).toBe(0);
		expect(env()).toContain(`\nREBAR3_VERSION=3.27.4\nREBAR3_SHA256=${sha256("escript")}\n`);
	});

	test.each([
		["clj-kondo/clj-kondo", "v2026.09.01", "v2026.09.01/clj-kondo-2026.09.01-macos-aarch64.zip", "CLJ_KONDO"],
		["plantuml/plantuml", "v1.2026.9", "v1.2026.9/native-plantuml-macos-arm64-1.2026.9.zip", "PLANTUML"],
	])("checksums %s's macOS arm64 download", async (repo, tag, path, key) => {
		github(repo, [[tag, OLD]]);
		serve(`https://github.com/${repo}/releases/download/${path}`, "zip");
		expect((await toolchain("bump")).code).toBe(0);
		expect(env()).toContain(`\n${key}_VERSION=${tag.slice(1)}\n${key}_SHA256=${sha256("zip")}\n`);
	});

	test("whose download fails leaves the pin, saying why", async () => {
		github("erlang/rebar3", [["3.27.4", OLD]]);
		const { code, out } = await toolchain("bump");
		expect(code).toBe(2);
		expect(out).toContain("pre-commit: scripts/toolchain.ts: could not move rebar3 to 3.27.4: ");
		expect(out).toContain("3.27.4/rebar3: curl: (22) 404");
		expect(env()).toContain("REBAR3_VERSION=3.27.3\n");
	});
});

test("GNU bash's checksum covers the release and its patches in order", async () => {
	bash("5.3", [
		[1, OLD],
		[2, OLD],
		[3, OLD],
	]);
	const bodies: [string, string][] = [
		["bash-5.3.tar.gz", "tar"],
		["bash-5.3-patches/bash53-001", "p1"],
		["bash-5.3-patches/bash53-002", "p2"],
		["bash-5.3-patches/bash53-003", "p3"],
	];
	for (const [file, body] of bodies) serve(`https://ftp.gnu.org/gnu/bash/${file}`, body);
	expect((await toolchain("bump")).code).toBe(0);
	expect(env()).toContain(`\nGNU_BASH_VERSION=5.3.3\nGNU_BASH_SHA256=${sha256("tarp1p2p3")}\n`);
});

test("Graphviz follows its GitLab releases and checksums the source tarball", async () => {
	graphviz([
		["16.2.0", hoursAgo(2)],
		["16.1.1", OLD],
		["16.1.0", OLD],
	]);
	serve(
		"https://gitlab.com/api/v4/projects/4207231/packages/generic/graphviz-releases/16.1.1/graphviz-16.1.1.tar.xz",
		"source",
	);
	const { code, out } = await toolchain("check");
	expect(code).toBe(1);
	expect(out).toContain("BLOCKED: Graphviz is pinned to 16.1.0; the target is 16.1.1");
	expect((await toolchain("bump")).code).toBe(0);
	expect(env()).toContain(`\nGRAPHVIZ_VERSION=16.1.1\nGRAPHVIZ_SHA256=${sha256("source")}\n`);
});

test("OTP counts a release 24h old once both runners have its build", async () => {
	otp(
		[
			["29.1.2", OLD],
			["29.1.3", OLD],
		],
		["29.1.2"],
	);
	expect((await toolchain("check")).code).toBe(0);

	otp([
		["29.1.2", OLD],
		["29.1.3", hoursAgo(2)],
	]);
	expect((await toolchain("check")).code).toBe(0);

	otp([
		["29.1.2", OLD],
		["29.1.3", OLD],
	]);
	expect((await toolchain("check")).code).toBe(1);
});

test("OTP stays on a major Elixir has no release 24h old built for", async () => {
	otp([
		["29.1.2", OLD],
		["30.0", OLD],
	]);
	elixir([
		["1.20.4-otp-29", OLD],
		["1.20.5-otp-30", hoursAgo(2)],
	]);
	const { code, out } = await toolchain("check");
	expect(code).toBe(0);
	expect(out).toContain("current: Erlang/OTP 29.1.2");
});

test("Elixir follows the OTP major it moves to", async () => {
	otp([
		["29.1.2", OLD],
		["30.0", OLD],
		["30.0-rc1", OLD],
	]);
	elixir([
		["1.20.4-otp-29", OLD],
		["1.20.4-otp-30", OLD],
		["1.21.0-otp-29", OLD],
	]);
	const { code, out } = await toolchain("bump");
	expect(code).toBe(0);
	expect(out).toContain("toolchain: Erlang/OTP 29.1.2 -> 30.0");
	expect(tools()).toBe("erlang 30.0\nelixir 1.20.4\nbun 1.4.3\n");
	expect((await toolchain("check")).code).toBe(0);
});

describe("a workflow action", () => {
	test("moves to its newest release's commit in every workflow and the toolchain action", async () => {
		github("actions/checkout", [
			["v7.0.1", OLD],
			["v6.9.0", OLD],
			["v7.1.0", OLD],
		]);
		commit("actions/checkout", "v7.1.0", CHECKOUT_NEXT);
		const { code, out } = await toolchain("check");
		expect(code).toBe(1);
		expect(out).toContain("BLOCKED: actions/checkout is pinned to v7.0.1; the target is v7.1.0");
		expect((await toolchain("bump")).code).toBe(0);
		for (const file of Object.keys(WORKFLOWS))
			expect(files.get(file)).toContain(`uses: actions/checkout@${CHECKOUT_NEXT} # v7.1.0\n`);
		expect(files.get(".github/workflows/ci.yml")).toContain("- uses: ./.github/actions/local\n");
	});

	test("pinned to a commit other than its tag's blocks, and the bump repins it", async () => {
		commit("actions/checkout", "v7.0.1", CHECKOUT_NEXT);
		const { code, out } = await toolchain("check");
		expect(code).toBe(1);
		expect(out).toContain(`BLOCKED: actions/checkout v7.0.1: ${CHECKOUT} is not v7.0.1's commit ${CHECKOUT_NEXT}`);
		expect((await toolchain("bump")).code).toBe(0);
		expect((await toolchain("check")).code).toBe(0);
	});

	test("takes its advisories from GitHub's actions advisories", async () => {
		github("actions/checkout", [
			["v7.0.1", OLD],
			["v7.0.2", hoursAgo(1)],
		]);
		commit("actions/checkout", "v7.0.2", CHECKOUT_NEXT);
		globalAdvisory("actions", "actions/checkout", "< 7.0.2");
		const { code, out } = await toolchain("check");
		expect(code).toBe(1);
		expect(out).toContain("the target is v7.0.2 (fixes an advisory");
	});

	test.each([
		"actions/checkout@v7",
		`actions/checkout@${"c".repeat(40)}`,
		`actions/checkout@${CHECKOUT} # main`,
	])("without a commit and tag pin fails closed (%s)", async (uses) => {
		files.set(".github/workflows/ci.yml", `    - uses: ${uses}\n`);
		const { code, out } = await toolchain("check");
		expect(code).toBe(2);
		expect(out).toContain("each remote action needs one `owner/repo@<sha> # <tag>` pin");
		expect(out).toContain(`.github/workflows/ci.yml: ${uses}`);
	});

	test("pinned two ways fails closed", async () => {
		files.set(".github/workflows/audit.yml", `    - uses: actions/checkout@${CHECKOUT_NEXT} # v7.0.1\n`);
		const { code, out } = await toolchain("check");
		expect(code).toBe(2);
		expect(out).toContain(".github/workflows/audit.yml: actions/checkout pinned two ways");
	});
});

describe("fails closed", () => {
	test("on a feed it cannot read, changing nothing", async () => {
		web.delete("https://builds.hex.pm/builds/elixir/builds.txt");
		for (const mode of ["check", "bump"]) {
			const { code, out } = await toolchain(mode);
			expect(code).toBe(2);
			expect(out).toContain("builds.hex.pm/builds/elixir/builds.txt: curl: (22) 404");
			expect(out).toContain(`${mode === "bump" ? "pre-commit: " : ""}scripts/toolchain.ts: `);
			expect(out).toContain("cannot check the toolchain");
		}
		expect(env()).toBe(ENV);
		expect(tools()).toBe(TOOL_VERSIONS);
	});

	test.each(['{"message": "Not Found"}', "not json"])("on an advisory feed it cannot read (%s)", async (body) => {
		serve("https://api.github.com/repos/oven-sh/bun/security-advisories?state=published&per_page=100", body);
		const { code, out } = await toolchain("check");
		expect(code).toBe(2);
		expect(out).toContain("cannot check the toolchain");
	});

	test.each([
		[".tool-versions", "erlang 29.1.2\nbun 1.4.3\n", ".tool-versions: no elixir"],
		["package.json", "{}", "package.json: no pnpm packageManager"],
		[".github/toolchain.env", undefined, ".github/toolchain.env: cannot read"],
	])("on a pin file that lacks a pin (%s)", async (path, body, why) => {
		if (body === undefined) files.delete(path);
		else files.set(path, body);
		const { code, out } = await toolchain("check");
		expect(code).toBe(2);
		expect(out).toContain(why);
	});

	test("on a release without a readable date", async () => {
		github("hexpm/hex", [["v2.5.3", "soon"]]);
		const { code, out } = await toolchain("check");
		expect(code).toBe(2);
		expect(out).toContain("hexpm/hex v2.5.3: no readable date");
	});

	test("on a source with no release 24h old", async () => {
		github("hexpm/hex", [["v2.5.3", hoursAgo(1)]]);
		const { code, out } = await toolchain("check");
		expect(code).toBe(2);
		expect(out).toContain("Hex: no release is 24h old");
	});

	test("on an unknown mode", async () => {
		expect(await toolchain("fix")).toEqual({ code: 2, out: "usage: bun scripts/toolchain.ts check|bump\n" });
	});
});

test("a pin on a release under 24h old is moved back to the target", async () => {
	github("oven-sh/bun", [
		["bun-v1.4.3", OLD],
		["bun-v1.4.4", hoursAgo(2)],
	]);
	pinBun("1.4.4");
	const { code, out } = await toolchain("check");
	expect(code).toBe(1);
	expect(out).toContain("BLOCKED: bun is pinned to 1.4.4; the target is 1.4.3");
	expect((await toolchain("bump")).code).toBe(0);
	expect(tools()).toContain("\nbun 1.4.3\n");
});

describe("a GitHub release list holding none of its releases", () => {
	test("is read again", async () => {
		// The second read lists only a pre-release, which counts as none.
		const real = web.get(BUN_RELEASES) as string;
		serve(BUN_RELEASES, (read) =>
			read === 1 ? "[]" : read === 2 ? releasesJson([["bun-v1.4.4", OLD, true]]) : real,
		);
		const { code, out } = await toolchain("check");
		expect(code).toBe(0);
		expect(out).toContain("current: bun 1.4.3");
		expect(reads.get(BUN_RELEASES)).toBe(3);
	});

	test("fails closed once every read holds none", async () => {
		github("oven-sh/bun", []);
		for (const mode of ["check", "bump"]) {
			const { code, out } = await toolchain(mode);
			expect(code).toBe(2);
			expect(out).toContain(
				"oven-sh/bun: GitHub listed no stable release whose tag matches " +
					"/^bun-v(\\d+\\.\\d+\\.\\d+)$/ in 5 reads — cannot check the toolchain.",
			);
		}
		expect(reads.get(BUN_RELEASES)).toBe(10);
		expect(tools()).toBe(TOOL_VERSIONS);
	});
});

test("Erlang and Elixir build lists are fetched once per run", async () => {
	expect((await toolchain("check")).code).toBe(0);
	expect(reads.get("https://builds.hex.pm/builds/elixir/builds.txt")).toBe(1);
	expect(reads.get("https://api.github.com/repos/elixir-lang/elixir/releases?per_page=100")).toBe(1);
});

// ------------------------------------------------------- pure functions

describe("compare", () => {
	test.each([
		["1.2.3", "1.2.3", 0],
		["v1.2.3", "1.2.3", 0],
		["1.2", "1.2.0", 0],
		["1.10.0", "1.9.9", 1],
		["1.2.3-rc1", "1.2.3", -1],
		["1.2.3", "1.2.3-rc1", 1],
		["1.2.3-rc1", "1.2.3-rc2", -1],
		["29.1.2.1", "29.1.2", 1],
	])("%s against %s", (a, b, sign) => {
		expect(Math.sign(compare(a, b))).toBe(sign);
	});
});

describe("inRange", () => {
	test.each([
		["1.4.3", ">= 1.0, < 1.4.4", true],
		["1.4.4", ">= 1.0, < 1.4.4", false],
		["0.9.0", ">= 1.0 and < 1.4.4", false],
		["2.0.0", "<= 2.0.0", true],
		["2.0.1", "≤ 2.0.0", false],
		["2.0.0", "> 2.0.0", false],
		["1.5.0", ">=1.0 <2.0", true],
		["1.4.3", "= 1.4.3", true],
		["1.4.3", "1.4.3", true],
		["1.4.3", "≥ v1.4.0", true],
		["1.4.3", "any", false],
	])("%s in %s", (version, range, inside) => {
		expect(inRange(version, range)).toBe(inside);
	});
});

describe("affects", () => {
	test("an open range per line stops at its line's patch", () => {
		const v = { range: ">= 18.0", patched: ["29.1.3", "28.5.0.9"], perLine: false };
		expect(affects(v, "29.1.2")).toBe(true);
		expect(affects(v, "29.1.3")).toBe(false);
		expect(affects(v, "28.5.0.8")).toBe(true);
		expect(affects(v, "30.0")).toBe(false);
	});

	test("an open per-line range with no patch covers only up to its advisory's newer lines", () => {
		expect(affects({ range: ">= 24.3.4.15", patched: [], perLine: true }, "25.0")).toBe(false);
		expect(affects({ range: ">= 24.3.4.15", patched: [], perLine: true }, "24.3.4.16")).toBe(true);
		expect(affects({ range: ">= 24.3.4.15", patched: [], perLine: false }, "29.0")).toBe(true);
	});
});

describe("target", () => {
	const rel = (version: string, hours: number) => ({ version, date: new Date(NOW - hours * 3_600_000) });

	test("is null when no release is 24h old", () => {
		expect(target([rel("1.0.0", 2)], [], "1.0.0", NOW)).toBeNull();
	});

	test("is the newest release 24h old", () => {
		expect(target([rel("1.0.0", 100), rel("1.1.0", 30), rel("1.2.0", 2)], [], "1.0.0", NOW)).toEqual({
			kind: "mature",
			version: "1.1.0",
		});
	});
});

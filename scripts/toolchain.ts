// Keeps the toolchain on the 24h release-age floor that Hex and pnpm
// apply to dependencies. Each pin, in .tool-versions (which mise and CI
// install from), .github/toolchain.env, package.json's packageManager, or
// a workflow's `uses: owner/repo@sha # tag`, must be the
// newest stable release at least 24h old. When a published advisory covers
// that release, the pin must instead be the lowest newer release that no
// advisory covers, however young.
//
//   bun scripts/toolchain.ts check   lists each pin that is off target and
//                                    exits 1 if any is (scripts/outdated.sh)
//   bun scripts/toolchain.ts bump    moves every pin onto its target
//                                    (scripts/bump-deps.sh)
//
// Both fail closed: a release list or advisory feed that cannot be read
// exits 2. HTTP goes through curl, so tests can stub it on PATH. GitHub
// requests carry GITHUB_TOKEN, or else gh's token, when there is one.

import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";

const DAY_MS = 86_400_000;
const WORKFLOWS = [".github/workflows/ci.yml", ".github/workflows/audit.yml"];
const now = Date.now();

export type Release = { version: string; date: Date };

class Unreadable extends Error {}

// ---------------------------------------------------------------- versions

function parts(version: string): { nums: number[]; pre: string } {
	const [core, ...pre] = version.replace(/^v/, "").split("-");
	return { nums: core.split(".").map(Number), pre: pre.join("-") };
}

// compare A B: negative, zero or positive as A is older, the same or newer.
// A pre-release sorts before its release.
export function compare(a: string, b: string): number {
	const x = parts(a);
	const y = parts(b);
	for (let i = 0; i < Math.max(x.nums.length, y.nums.length); i++) {
		const d = (x.nums[i] ?? 0) - (y.nums[i] ?? 0);
		if (d !== 0) return d;
	}
	if (x.pre === y.pre) return 0;
	if (!x.pre) return 1;
	if (!y.pre) return -1;
	return x.pre < y.pre ? -1 : 1;
}

// inRange VERSION RANGE: whether VERSION satisfies every comparator in an
// advisory's range, written as GitHub writes them: ">= 1.0, < 1.2",
// ">= 1.0 and < 1.2", "≥ 1.0", ">=1.0 <2.0" or "< 1.2".
export function inRange(version: string, range: string): boolean {
	const comparators = [
		...range.matchAll(/(>=|<=|≥|≤|>|<|=)?\s*v?(\d[\w.+-]*)/g),
	];
	if (comparators.length === 0) return false;
	return comparators.every(([, op = "=", bound]) => {
		const d = compare(version, bound);
		switch (op) {
			case ">=":
			case "≥":
				return d >= 0;
			case "<=":
			case "≤":
				return d <= 0;
			case ">":
				return d > 0;
			case "<":
				return d < 0;
			default:
				return d === 0;
		}
	});
}

export type Target = { version: string; fixes: boolean } | null;

// target RELEASES RANGES: the newest release at least 24h old or, when a
// vulnerable range covers it, the lowest newer release none covers. Null
// when no release is 24h old.
export function target(
	releases: Release[],
	ranges: string[],
	at = now,
): Target {
	const sorted = [...releases].sort((a, b) => compare(b.version, a.version));
	const mature = sorted.find((r) => at - r.date.getTime() >= DAY_MS);
	if (!mature) return null;
	const affected = (v: string) => ranges.some((r) => inRange(v, r));
	if (!affected(mature.version)) return { version: mature.version, fixes: false };
	const fix = sorted
		.filter((r) => compare(r.version, mature.version) > 0 && !affected(r.version))
		.at(-1);
	return fix
		? { version: fix.version, fixes: true }
		: { version: mature.version, fixes: false };
}

// -------------------------------------------------------------------- http

let tokenPromise: Promise<string> | undefined;
function githubToken(): Promise<string> {
	tokenPromise ??= (async () => {
		if (process.env.GITHUB_TOKEN) return process.env.GITHUB_TOKEN;
		const gh = Bun.spawn(["gh", "auth", "token"], {
			stdout: "pipe",
			stderr: "ignore",
		});
		const out = (await new Response(gh.stdout).text()).trim();
		return (await gh.exited) === 0 ? out : "";
	})().catch(() => "");
	return tokenPromise;
}

async function curl(
	url: string,
	opts: { head?: boolean } = {},
): Promise<Uint8Array> {
	const args = ["curl", "-sSfL", "--max-time", "60", "-K", "-"];
	if (opts.head) args.push("-I");
	let config = "";
	if (url.startsWith("https://api.github.com/")) {
		const token = await githubToken();
		config = 'header = "Accept: application/vnd.github+json"\n';
		if (token) config += `header = "Authorization: Bearer ${token}"\n`;
	}
	args.push(url);
	// The token goes in a curl config on stdin, kept out of the process list.
	const proc = Bun.spawn(args, {
		stdin: new TextEncoder().encode(config),
		stdout: "pipe",
		stderr: "pipe",
	});
	const [body, err, code] = await Promise.all([
		new Response(proc.stdout).bytes(),
		new Response(proc.stderr).text(),
		proc.exited,
	]);
	if (code !== 0) throw new Unreadable(`${url}: ${err.trim() || `curl exit ${code}`}`);
	return body;
}

async function text(url: string): Promise<string> {
	return new TextDecoder().decode(await curl(url));
}

async function json(url: string): Promise<unknown> {
	const body = await text(url);
	try {
		return JSON.parse(body);
	} catch {
		throw new Unreadable(`${url}: not JSON`);
	}
}

function date(value: unknown, what: string): Date {
	const d = new Date(String(value));
	if (Number.isNaN(d.getTime())) throw new Unreadable(`${what}: no readable date`);
	return d;
}

export async function sha256(...urls: string[]): Promise<string> {
	const hash = createHash("sha256");
	for (const url of urls) hash.update(await curl(url));
	return hash.digest("hex");
}

// ----------------------------------------------------------- release feeds

// githubReleases REPO TAG: REPO's published, non-pre-release GitHub
// releases whose tag matches TAG, versioned by TAG's first group.
async function githubReleases(repo: string, tag: RegExp): Promise<Release[]> {
	const list = await json(
		`https://api.github.com/repos/${repo}/releases?per_page=100`,
	);
	if (!Array.isArray(list)) throw new Unreadable(`${repo} releases: not a list`);
	return list.flatMap((r) => {
		const m = !r.draft && !r.prerelease && String(r.tag_name).match(tag);
		return m ? [{ version: m[1], date: date(r.published_at, `${repo} ${r.tag_name}`) }] : [];
	});
}

// repoAdvisories REPO NAME: the vulnerable ranges of REPO's published
// security advisories for the package NAME.
async function repoAdvisories(repo: string, name: string): Promise<string[]> {
	const list = await json(
		`https://api.github.com/repos/${repo}/security-advisories?state=published&per_page=100`,
	);
	if (!Array.isArray(list)) throw new Unreadable(`${repo} advisories: not a list`);
	return ranges(list, name);
}

// globalAdvisories ECOSYSTEM NAME: the vulnerable ranges of GitHub's
// reviewed advisories for NAME.
async function globalAdvisories(ecosystem: string, name: string): Promise<string[]> {
	const list = await json(
		`https://api.github.com/advisories?ecosystem=${ecosystem}&affects=${encodeURIComponent(name)}&per_page=100`,
	);
	if (!Array.isArray(list)) throw new Unreadable(`${name} advisories: not a list`);
	return ranges(list, name);
}

function ranges(advisories: unknown[], name: string): string[] {
	return advisories.flatMap((a) => {
		const adv = a as { withdrawn_at?: string; vulnerabilities?: unknown[] };
		if (adv.withdrawn_at) return [];
		return (adv.vulnerabilities ?? []).flatMap((v) => {
			const vuln = v as { package?: { name?: string }; vulnerable_version_range?: string };
			return vuln.package?.name?.toLowerCase() === name.toLowerCase() &&
				vuln.vulnerable_version_range
				? [vuln.vulnerable_version_range]
				: [];
		});
	});
}

// buildList URL PATTERN: dated builds from a list of "name ... date" lines
// (CSV or space-separated) whose name matches PATTERN's first group.
async function buildList(url: string, pattern: RegExp): Promise<Release[]> {
	return (await text(url)).split("\n").flatMap((line) => {
		const [name, , when] = line.split(/[ ,]/);
		const m = name?.match(pattern);
		return m ? [{ version: m[1], date: date(when, `${url} ${name}`) }] : [];
	});
}

// OTP builds for the runners CI uses: macOS arm64 (ci.yml) and Ubuntu
// 24.04 (audit.yml). A version counts once both have it, from the later.
async function otpReleases(): Promise<Release[]> {
	const stable = /^OTP-(\d+(?:\.\d+)*)$/;
	const [mac, ubuntu] = await Promise.all([
		buildList(
			"https://raw.githubusercontent.com/erlef/otp_builds/refs/heads/main/builds/aarch64-apple-darwin.csv",
			stable,
		),
		buildList("https://builds.hex.pm/builds/otp/ubuntu-24.04/builds.txt", stable),
	]);
	return mac.flatMap((m) => {
		const u = ubuntu.find((x) => x.version === m.version);
		return u ? [{ version: m.version, date: m.date > u.date ? m.date : u.date }] : [];
	});
}

// npmReleases NAME: NAME's releases up to its "latest" dist-tag; newer
// ones are tagged for testing, such as pnpm's "next-12".
async function npmReleases(name: string): Promise<Release[]> {
	const doc = (await json(`https://registry.npmjs.org/${name}`)) as {
		time?: Record<string, string>;
		"dist-tags"?: { latest?: string };
	};
	const latest = doc["dist-tags"]?.latest;
	if (!doc.time || !latest) throw new Unreadable(`${name}: npm lists no publish times`);
	return Object.entries(doc.time).flatMap(([version, when]) =>
		/^\d+\.\d+\.\d+$/.test(version) && compare(version, latest) <= 0
			? [{ version, date: date(when, `${name} ${version}`) }]
			: [],
	);
}

// GNU bash: a release is a version with its official patches, as
// "5.3.9", dated by the newest file's Last-Modified.
const GNU = "https://ftp.gnu.org/gnu/bash";

export function gnuBashFiles(version: string): string[] {
	const [major, minor, level = "0"] = version.split(".");
	const base = `${major}.${minor}`;
	const files = [`${GNU}/bash-${base}.tar.gz`];
	for (let i = 1; i <= Number(level); i++)
		files.push(`${GNU}/bash-${base}-patches/bash${major}${minor}-${String(i).padStart(3, "0")}`);
	return files;
}

async function lastModified(url: string): Promise<Date> {
	const headers = new TextDecoder().decode(await curl(url, { head: true }));
	const m = [...headers.matchAll(/^last-modified:\s*(.+?)\s*$/gim)].at(-1);
	return date(m?.[1], `${url} Last-Modified`);
}

async function gnuBashReleases(): Promise<Release[]> {
	const bases = [...(await text(`${GNU}/`)).matchAll(/href="bash-(\d+\.\d+)\.tar\.gz"/g)]
		.map((m) => m[1])
		.sort(compare);
	const base = bases.at(-1);
	if (!base) throw new Unreadable(`${GNU}/: lists no bash release`);
	const [major, minor] = base.split(".");
	const patches = [
		...(await text(`${GNU}/bash-${base}-patches/`)).matchAll(
			new RegExp(`href="bash${major}${minor}-(\\d{3})"`, "g"),
		),
	].map((m) => Number(m[1]));
	const level = Math.max(0, ...patches);
	// Only the newest patch levels can be under 24h old; date each down
	// to the first that is not.
	const releases: Release[] = [];
	for (let i = level; i >= 0; i--) {
		const version = `${base}.${i}`;
		const date = await lastModified(gnuBashFiles(version).at(-1) as string);
		releases.push({ version, date });
		if (now - date.getTime() >= DAY_MS) break;
	}
	return releases;
}

// Graphviz releases on GitLab, with the source tarball as a package.
const GRAPHVIZ = "https://gitlab.com/api/v4/projects/4207231";

export function graphvizFiles(version: string): string[] {
	return [`${GRAPHVIZ}/packages/generic/graphviz-releases/${version}/graphviz-${version}.tar.xz`];
}

async function graphvizReleases(): Promise<Release[]> {
	const list = await json(`${GRAPHVIZ}/releases?per_page=100`);
	if (!Array.isArray(list)) throw new Unreadable("graphviz releases: not a list");
	return list.flatMap((r) => {
		const m = String(r.tag_name).match(/^(\d+\.\d+\.\d+)$/);
		return m && !r.upcoming_release
			? [{ version: m[1], date: date(r.released_at, `graphviz ${r.tag_name}`) }]
			: [];
	});
}

// ------------------------------------------------------------------- pins

function readFile(path: string): string {
	try {
		return readFileSync(path, "utf8");
	} catch {
		throw new Unreadable(`${path}: cannot read`);
	}
}

// A file of pins, one per line: .tool-versions' "name version" or
// toolchain.env's "KEY=value".
type PinFile = { path: string; line: (key: string) => RegExp; format: (key: string, value: string) => string };

const TOOL_VERSIONS: PinFile = {
	path: ".tool-versions",
	line: (key) => new RegExp(`^${key}[ \\t]+(\\S+).*$`, "m"),
	format: (key, value) => `${key} ${value}`,
};

const TOOLCHAIN_ENV: PinFile = {
	path: ".github/toolchain.env",
	line: (key) => new RegExp(`^${key}=(.*)$`, "m"),
	format: (key, value) => `${key}=${value}`,
};

function getPin(file: PinFile, key: string): string {
	const m = readFile(file.path).match(file.line(key));
	if (!m) throw new Unreadable(`${file.path}: no ${key}`);
	return m[1];
}

function setPins(file: PinFile, values: Record<string, string>) {
	let body = readFile(file.path);
	for (const [key, value] of Object.entries(values)) {
		if (!file.line(key).test(body)) throw new Unreadable(`${file.path}: no ${key}`);
		body = body.replace(file.line(key), file.format(key, value));
	}
	writeFileSync(file.path, body);
}

type Pin = {
	name: string;
	current: string;
	releases: () => Promise<Release[]>;
	advisories: () => Promise<string[]>;
	// Rewrites the pin to VERSION.
	bump: (version: string) => Promise<void>;
	// Extra checks on the pin as it stands, each a reason it is wrong.
	verify?: () => Promise<string[]>;
};

// filePin: the pin KEY in FILE. With ASSET, the release's download URLs,
// the file also holds their combined SHA-256 under SHA_KEY.
function filePin(
	file: PinFile,
	key: string,
	name: string,
	releases: () => Promise<Release[]>,
	advisories: () => Promise<string[]>,
	asset?: { shaKey: string; urls: (version: string) => string[] },
): Pin {
	return {
		name,
		current: getPin(file, key),
		releases,
		advisories,
		bump: async (version) =>
			setPins(file, {
				[key]: version,
				...(asset ? { [asset.shaKey]: await sha256(...asset.urls(version)) } : {}),
			}),
	};
}

const none = async () => [] as string[];

function filePins(): Pin[] {
	const otp = getPin(TOOL_VERSIONS, "erlang");
	const download = (repo: string, path: (v: string) => string) => (v: string) => [
		`https://github.com/${repo}/releases/download/${path(v)}`,
	];
	return [
		filePin(TOOL_VERSIONS, "erlang", "Erlang/OTP", otpReleases, () =>
			repoAdvisories("erlang/otp", "OTP"),
		),
		// Hex builds Elixir for each OTP major.
		filePin(
			TOOL_VERSIONS,
			"elixir",
			"Elixir",
			() =>
				buildList(
					"https://builds.hex.pm/builds/elixir/builds.txt",
					new RegExp(`^v(\\d+\\.\\d+\\.\\d+)-otp-${otp.split(".")[0]}$`),
				),
			() => repoAdvisories("elixir-lang/elixir", "elixir"),
		),
		filePin(
			TOOL_VERSIONS,
			"bun",
			"bun",
			() => githubReleases("oven-sh/bun", /^bun-v(\d+\.\d+\.\d+)$/),
			() => repoAdvisories("oven-sh/bun", "bun"),
		),
		filePin(
			TOOLCHAIN_ENV,
			"HEX_VERSION",
			"Hex",
			() => githubReleases("hexpm/hex", /^v(\d+\.\d+\.\d+)$/),
			() => repoAdvisories("hexpm/hex", "hex"),
		),
		filePin(
			TOOLCHAIN_ENV,
			"REBAR3_VERSION",
			"rebar3",
			() => githubReleases("erlang/rebar3", /^(\d+\.\d+\.\d+)$/),
			() => repoAdvisories("erlang/rebar3", "rebar3"),
			{ shaKey: "REBAR3_SHA256", urls: download("erlang/rebar3", (v) => `${v}/rebar3`) },
		),
		filePin(
			TOOLCHAIN_ENV,
			"CLJ_KONDO_VERSION",
			"clj-kondo",
			() => githubReleases("clj-kondo/clj-kondo", /^v(\d{4}\.\d{2}\.\d{2})$/),
			() => repoAdvisories("clj-kondo/clj-kondo", "clj-kondo"),
			{
				shaKey: "CLJ_KONDO_SHA256",
				urls: download("clj-kondo/clj-kondo", (v) => `v${v}/clj-kondo-${v}-macos-aarch64.zip`),
			},
		),
		filePin(
			TOOLCHAIN_ENV,
			"PLANTUML_VERSION",
			"PlantUML",
			() => githubReleases("plantuml/plantuml", /^v(\d+\.\d+\.\d+)$/),
			() => repoAdvisories("plantuml/plantuml", "plantuml"),
			{
				shaKey: "PLANTUML_SHA256",
				urls: download("plantuml/plantuml", (v) => `v${v}/native-plantuml-macos-arm64-${v}.zip`),
			},
		),
		// GNU publishes no advisory feed for bash.
		filePin(TOOLCHAIN_ENV, "GNU_BASH_VERSION", "GNU bash", gnuBashReleases, none, {
			shaKey: "GNU_BASH_SHA256",
			urls: gnuBashFiles,
		}),
		// GitHub's advisory database lists nothing for Graphviz.
		filePin(TOOLCHAIN_ENV, "GRAPHVIZ_VERSION", "Graphviz", graphvizReleases, none, {
			shaKey: "GRAPHVIZ_SHA256",
			urls: graphvizFiles,
		}),
	];
}

function pnpmPin(): Pin {
	const pkg = readFile("package.json");
	const current = pkg.match(/"packageManager":\s*"pnpm@([^"]+)"/)?.[1];
	if (!current) throw new Unreadable("package.json: no pnpm packageManager");
	return {
		name: "pnpm",
		current,
		releases: () => npmReleases("pnpm"),
		advisories: () => globalAdvisories("npm", "pnpm"),
		bump: async (version) =>
			writeFileSync(
				"package.json",
				readFile("package.json").replace(
					/("packageManager":\s*"pnpm@)[^"]+"/,
					`$1${version}"`,
				),
			),
	};
}

// actionPins: one pin per action repo the workflows use, as
// `uses: owner/repo[/path]@<40-hex sha> # <tag>`.
function actionPins(): Pin[] {
	const uses = new Map<string, { sha: string; tag: string }>();
	const bad: string[] = [];
	for (const file of WORKFLOWS) {
		for (const line of readFile(file).split("\n")) {
			const m = line.match(/^\s*(?:-\s+)?uses:\s*(\S+)(.*)$/);
			if (!m || m[1].startsWith("./")) continue;
			const pin = m[1].match(/^([\w.-]+\/[\w.-]+)(?:\/[^@]*)?@([0-9a-f]{40})$/);
			const tag = m[2].match(/^\s+#\s+(v?\d+(?:\.\d+)*)\s*$/)?.[1];
			if (!pin || !tag) {
				bad.push(`${file}: ${m[1]}${m[2]}`);
				continue;
			}
			const seen = uses.get(pin[1]);
			if (seen && (seen.sha !== pin[2] || seen.tag !== tag))
				bad.push(`${file}: ${pin[1]} pinned two ways`);
			uses.set(pin[1], { sha: pin[2], tag });
		}
	}
	if (bad.length)
		throw new Unreadable(
			`each remote action needs one \`owner/repo@<sha> # <tag>\` pin:\n  ${bad.join("\n  ")}`,
		);
	return [...uses].map(([repo, { sha, tag }]) => ({
		name: repo,
		current: tag,
		releases: () => githubReleases(repo, /^(v?\d+(?:\.\d+)*)$/),
		advisories: () => globalAdvisories("actions", repo),
		verify: async () => {
			const real = await tagSha(repo, tag);
			return real === sha ? [] : [`${sha} is not ${tag}'s commit ${real}`];
		},
		bump: async (version) => {
			const next = await tagSha(repo, version);
			for (const file of WORKFLOWS) {
				const escaped = repo.replace(/[.]/g, "\\.");
				writeFileSync(
					file,
					readFile(file).replace(
						new RegExp(`(uses:\\s*${escaped}(?:/[^@\\s]*)?@)[0-9a-f]{40}(\\s+#\\s+)\\S+`, "g"),
						`$1${next}$2${version}`,
					),
				);
			}
		},
	}));
}

async function tagSha(repo: string, tag: string): Promise<string> {
	const commit = (await json(`https://api.github.com/repos/${repo}/commits/${tag}`)) as {
		sha?: string;
	};
	if (!commit.sha) throw new Unreadable(`${repo} ${tag}: no commit`);
	return commit.sha;
}

// -------------------------------------------------------------------- main

type Verdict = { pin: Pin; target: Target; problems: string[] };

async function judge(pin: Pin): Promise<Verdict> {
	const [releases, advisories, problems] = await Promise.all([
		pin.releases(),
		pin.advisories(),
		pin.verify?.() ?? Promise.resolve([]),
	]);
	const t = target(releases, advisories);
	if (!t) throw new Unreadable(`${pin.name}: no release is 24h old`);
	return { pin, target: t, problems };
}

async function main(mode: string): Promise<number> {
	if (mode !== "check" && mode !== "bump") {
		console.error("usage: bun scripts/toolchain.ts check|bump");
		return 2;
	}
	const prefix = mode === "check" ? "" : "pre-commit: ";
	let verdicts: Verdict[];
	try {
		// The Elixir pin follows the OTP major, so OTP moves first.
		let pins = [...filePins(), pnpmPin(), ...actionPins()];
		if (mode === "bump") {
			const otp = pins.find((p) => p.name === "Erlang/OTP") as Pin;
			const want = (await judge(otp)).target?.version as string;
			if (otp.current !== want) {
				await otp.bump(want);
				console.log(`${prefix}toolchain: ${otp.name} ${otp.current} -> ${want}`);
			}
			pins = [...filePins(), pnpmPin(), ...actionPins()];
		}
		verdicts = await Promise.all(pins.map(judge));
	} catch (e) {
		console.error(
			`${prefix}scripts/toolchain.ts: ${e instanceof Error ? e.message : e} — cannot check the toolchain.`,
		);
		return 2;
	}
	let off = 0;
	for (const { pin, target: t, problems } of verdicts) {
		const want = t?.version as string;
		const why = t?.fixes ? " (fixes an advisory on the newest release 24h old)" : "";
		if (pin.current === want && problems.length === 0) {
			if (mode === "check") console.log(`current: ${pin.name} ${want}${why}`);
			continue;
		}
		off++;
		if (mode === "check") {
			for (const p of problems) console.log(`BLOCKED: ${pin.name} ${pin.current}: ${p}`);
			if (pin.current !== want)
				console.log(`BLOCKED: ${pin.name} is pinned to ${pin.current}; the target is ${want}${why}`);
			continue;
		}
		try {
			await pin.bump(want);
		} catch (e) {
			console.error(
				`${prefix}scripts/toolchain.ts: could not move ${pin.name} to ${want}: ${e instanceof Error ? e.message : e}`,
			);
			return 2;
		}
		console.log(`${prefix}toolchain: ${pin.name} ${pin.current} -> ${want}${why}`);
	}
	return mode === "check" && off > 0 ? 1 : 0;
}

if (import.meta.main) process.exit(await main(process.argv[2] ?? ""));

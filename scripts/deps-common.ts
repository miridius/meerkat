// Shared by scripts/outdated.ts (the pre-push gate) and scripts/bump-deps.ts
// (the dependency bump), run from the repo root, so both read the
// exemptions and the two outdated reports the same way.
//
// Every process, file and clock either script uses goes through a `Sys`,
// so their tests drive them on literal reports. A function that fails
// prints why, prefixed with `sys.prefix`, and throws `Failed`; the script
// then exits with its code, 1 unless it gives another.

import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

export type Ran = { code: number; stdout: string; stderr: string };
export type RunOptions = {
	cwd?: string;
	// Entries set to undefined are removed from the environment.
	env?: Record<string, string | undefined>;
	stdin?: string;
	// Streams the output instead of capturing it.
	inherit?: boolean;
};

export interface Sys {
	prefix: string;
	env: Record<string, string | undefined>;
	run(cmd: string[], options?: RunOptions): Promise<Ran>;
	out(text: string): void;
	err(text: string): void;
	read(path: string): string | null;
	write(path: string, text: string): void;
	which(tool: string): boolean;
	now(): number;
	// A scratch copy of the pnpm workspace, or null when it cannot be made.
	scratchWorkspace(): string | null;
	remove(path: string): void;
}

export class Failed extends Error {
	constructor(
		message: string,
		readonly code = 1,
	) {
		super(message);
	}
}

export const DAY_MS = 86_400_000;

export function fail(sys: Sys, message: string): never {
	sys.out(`${sys.prefix} ${message}`);
	throw new Failed(message);
}

// The real Sys, with relative paths read from the current directory.
export function realSys(prefix: string): Sys {
	return {
		prefix,
		env: process.env,
		async run(cmd, options = {}) {
			const env = { ...process.env, ...options.env };
			for (const [key, value] of Object.entries(env)) if (value === undefined) delete env[key];
			const io = options.inherit ? "inherit" : "pipe";
			const proc = Bun.spawn(cmd, {
				cwd: options.cwd,
				env,
				stdin: options.stdin === undefined ? "ignore" : new Blob([options.stdin]),
				stdout: io,
				stderr: io,
			});
			const [stdout, stderr, code] = await Promise.all([
				options.inherit ? "" : new Response(proc.stdout as ReadableStream).text(),
				options.inherit ? "" : new Response(proc.stderr as ReadableStream).text(),
				proc.exited,
			]);
			return { code, stdout, stderr };
		},
		out: (text) => console.log(text),
		err: (text) => console.error(text),
		read(path) {
			try {
				return readFileSync(path, "utf8");
			} catch {
				return null;
			}
		},
		write: (path, text) => writeFileSync(path, text),
		which: (tool) => Bun.which(tool) !== null,
		now: () => Date.now(),
		scratchWorkspace: () => scratchWorkspace("."),
		remove: (path) => rmSync(path, { recursive: true, force: true }),
	};
}

// scratchWorkspace ROOT: a new temporary dir holding ROOT's pnpm workspace
// manifests, lockfile and patches/, with deps/ linked to ROOT's, or null.
export function scratchWorkspace(root: string): string | null {
	let tmp: string | undefined;
	try {
		tmp = mkdtempSync(join(tmpdir(), "meerkat-pnpm-"));
		mkdirSync(join(tmp, "assets"));
		for (const file of ["package.json", "pnpm-workspace.yaml", "pnpm-lock.yaml", "assets/package.json"])
			cpSync(join(root, file), join(tmp, file));
		// pnpm-workspace.yaml's patchedDependencies name files in patches/.
		const patches = join(root, "patches");
		if (existsSync(patches) && statSync(patches).isDirectory())
			cpSync(patches, join(tmp, "patches"), { recursive: true });
		// assets/package.json takes the Phoenix packages from ../deps.
		symlinkSync(resolve(root, "deps"), join(tmp, "deps"));
		return tmp;
	} catch {
		if (tmp) rmSync(tmp, { recursive: true, force: true });
		return null;
	}
}

// Bash's $(...) drops trailing newlines; output is printed the same way.
const chomp = (text: string) => text.replace(/\n+$/, "");

// requireTools TOOL...: fails when any TOOL is not on PATH.
export function requireTools(sys: Sys, ...tools: string[]) {
	for (const tool of tools)
		if (!sys.which(tool)) fail(sys, `required tool '${tool}' missing — cannot check dependencies.`);
}

// withoutGitEnv: the environment change that drops GIT_INDEX_FILE and the
// other variables Git exports to hooks, as scripts/check.sh does, so
// fetching a git dependency into deps/ leaves this checkout's index alone.
export async function withoutGitEnv(sys: Sys): Promise<Record<string, undefined>> {
	const ran = await sys.run(["git", "rev-parse", "--local-env-vars"]);
	return Object.fromEntries(ran.stdout.split(/\s+/).filter(Boolean).map((name) => [name, undefined]));
}

// syncLockedDeps: installs the versions mix.lock and pnpm-lock.yaml name
// into deps/ and node_modules/, which a rebase or branch switch can leave
// at the previous lockfiles'. The reports need them: hex.outdated aborts
// while deps/ differs from mix.lock, and pnpm outdated reads current
// releases from node_modules/. Hex goes first, since assets/package.json
// takes the Phoenix packages from deps/. Both fail rather than rewrite a
// lockfile.
export async function syncLockedDeps(sys: Sys) {
	const env = await withoutGitEnv(sys);
	const steps: [string[], string][] = [
		[["mix", "deps.get", "--check-locked"], "mix deps.get --check-locked failed — cannot check Hex deps against mix.lock."],
		[
			["pnpm", "install", "--frozen-lockfile", "--ignore-scripts", "--prefer-offline"],
			"pnpm install --frozen-lockfile failed — cannot check JS deps against pnpm-lock.yaml.",
		],
	];
	for (const [cmd, why] of steps) {
		const ran = await sys.run(cmd, { env });
		if (ran.code !== 0) {
			sys.out(chomp(ran.stdout + ran.stderr));
			fail(sys, why);
		}
	}
}

// An entry declines one upstream release, `version`, and says why.
export type Exemptions = Record<string, { version: string; reason: string }>;

// parseExemptions TEXT: scripts/dep-exemptions.json's map of package name
// to {version, reason}, or null when TEXT is not one with non-empty
// strings for both.
export function parseExemptions(text: string | null): Exemptions | null {
	let table: unknown;
	try {
		table = JSON.parse(text ?? "");
	} catch {
		return null;
	}
	const filled = (v: unknown) => typeof v === "string" && v.length > 0;
	const isObject = (v: unknown): v is Record<string, unknown> =>
		typeof v === "object" && v !== null && !Array.isArray(v);
	if (!isObject(table)) return null;
	for (const entry of Object.values(table))
		if (!isObject(entry) || !filled(entry.version) || !filled(entry.reason)) return null;
	return table as Exemptions;
}

export function loadExemptions(sys: Sys): Exemptions {
	return (
		parseExemptions(sys.read("scripts/dep-exemptions.json")) ??
		fail(
			sys,
			'scripts/dep-exemptions.json is missing or malformed — each entry needs a "version" and a "reason".',
		)
	);
}

export type JsRow = { name: string; latest: string };

// parsePnpmOutdated JSON: a row per package in `pnpm -r outdated --format
// json`'s report, or null unless it is an object giving each a latest.
export function parsePnpmOutdated(json: string): JsRow[] | null {
	let report: unknown;
	try {
		report = JSON.parse(json);
	} catch {
		return null;
	}
	if (typeof report !== "object" || report === null || Array.isArray(report)) return null;
	const rows: JsRow[] = [];
	for (const [name, entry] of Object.entries(report)) {
		const latest = (entry as { latest?: unknown } | null)?.latest;
		if (typeof latest !== "string") return null;
		rows.push({ name, latest });
	}
	return rows;
}

// pnpmOutdated ARG...: the JS dependencies behind latest, across the
// workspace. pnpm's latest is the newest release past minimumReleaseAge,
// so it can trail npmLatest, and a package installed at that release is
// left out; ARGs go to pnpm, so --config.minimum-release-age=0 reports the
// registry's latest instead.
export async function pnpmOutdated(sys: Sys, ...args: string[]): Promise<JsRow[]> {
	// pnpm outdated exits 1 when it FINDS outdated deps, so the exit code
	// alone can't tell findings from breakage: a JSON object on stdout is
	// the success signal. Warnings go to stderr, kept out of the JSON.
	const ran = await sys.run(["pnpm", "-r", "outdated", "--format", "json", ...args]);
	const rows = ran.code > 1 ? null : parsePnpmOutdated(ran.stdout);
	if (rows) return rows;
	if (ran.stderr) sys.out(chomp(ran.stderr));
	sys.out(chomp(ran.stdout));
	const shown = args.length ? ` ${args.join(" ")}` : "";
	return fail(sys, `pnpm outdated${shown} produced no JSON report (exit ${ran.code}) — cannot check JS deps.`);
}

// pnpmInstallable NAME: "ok" when pnpm, under minimumReleaseAge, resolves
// `pnpm -r update --latest NAME`, and "young", printing pnpm's reason, when
// it refuses because a dependency of that release has no version in its
// range past the floor. pnpm outdated judges a release by its own publish
// time only, so a release past the floor can still require a younger
// version, such as an exact-pinned platform build published minutes
// later. The update runs on a scratch copy of the workspace manifests and
// lockfile, so the tree is left alone.
export async function pnpmInstallable(sys: Sys, name: string): Promise<"ok" | "young"> {
	const tmp = sys.scratchWorkspace();
	if (tmp === null) fail(sys, `could not copy the workspace to a scratch dir — cannot check ${name} is installable.`);
	let ran: Ran;
	try {
		ran = await sys.run(["pnpm", "-r", "update", "--latest", "--lockfile-only", "--ignore-scripts", name], {
			cwd: tmp,
		});
	} finally {
		sys.remove(tmp);
	}
	if (ran.code === 0) return "ok";
	const out = ran.stdout + ran.stderr;
	const reason = out.split("\n").find((line) => line.includes("ERR_PNPM_NO_MATURE_MATCHING_VERSION"));
	if (reason !== undefined) {
		sys.out(reason);
		return "young";
	}
	sys.out(chomp(out));
	return fail(sys, `pnpm could not resolve ${name}'s latest release (exit ${ran.code}) — cannot check it is installable.`);
}

// npmLatest NAME: the release NAME's "latest" dist-tag names on the
// registry, however young it is. Its failure message goes to stderr.
export async function npmLatest(sys: Sys, name: string): Promise<string> {
	const ran = await sys.run(["pnpm", "view", name, "dist-tags.latest"]);
	const latest = chomp(ran.stdout);
	if (ran.code === 0 && /^\S+$/.test(latest)) return latest;
	if (ran.stderr) sys.err(chomp(ran.stderr));
	const message = `could not read ${name}'s latest release from the registry — cannot check its exemption.`;
	sys.err(`${sys.prefix} ${message}`);
	throw new Failed(message);
}

export type HexStatus = "possible" | "not" | "cooldown";
export type HexRow = { name: string; latest: string; status: HexStatus };

// parseHexOutdated OUT: a row per Hex dependency behind latest in `mix
// hex.outdated`'s report OUT, or null when OUT has no dependency table or
// a row with a status it does not know. status is "possible", "not" when a
// requirement (in mix.exs or another dependency) excludes latest, or
// "cooldown" when latest is under the 24h Hex cooldown mix.exs sets.
export function parseHexOutdated(out: string): HexRow[] | null {
	const statuses: Record<string, HexStatus> = {
		"Update possible (cooldown)": "cooldown",
		"Update possible": "possible",
		"Update not possible": "not",
	};
	let table = false;
	const rows: HexRow[] = [];
	for (const line of out.split("\n")) {
		if (line.startsWith("Dependency ")) {
			table = true;
			continue;
		}
		if (!table) continue;
		const fields = line.trim().split(/\s+/).filter(Boolean);
		if (fields.length === 0) break;
		// Only is optional, so find Status by its first word.
		const at = fields.findIndex((field, i) => i >= 3 && (field === "Up-to-date" || field === "Update"));
		if (at === -1) return null;
		const status = fields.slice(at).join(" ");
		if (status.startsWith("Up-to-date")) continue;
		if (!(status in statuses)) return null;
		rows.push({ name: fields[0], latest: fields[at - 1], status: statuses[status] });
	}
	return table ? rows : null;
}

// hexPackage NAME: hex.pm's record of NAME, as `curl` fetched it.
export function hexPackage(sys: Sys, name: string): Promise<Ran> {
	return sys.run(["curl", "-sSf", "--max-time", "10", `https://hex.pm/api/packages/${name}`]);
}

// publishedAt BODY VERSION: when hex.pm's record BODY says VERSION was
// published, or why that cannot be read.
export function publishedAt(body: string, version: string): Date | string {
	let doc: { releases?: { version?: string; inserted_at?: string }[] };
	try {
		doc = JSON.parse(body);
	} catch (e) {
		return `hex.pm sent no JSON (${e instanceof Error ? e.message : e})`;
	}
	const date = new Date(String(doc?.releases?.find?.((r) => r.version === version)?.inserted_at));
	return Number.isNaN(date.getTime()) ? `hex.pm's record lists no publish time for ${version}` : date;
}

// markCooldown ROWS: ROWS, with each a requirement excludes marked
// "cooldown" while hex.pm published its latest release under 24h ago, the
// cooldown mix.exs sets. Hex marks its cooldown only on a release the
// requirements admit, so hex.pm's publish time decides it for the rest.
export async function markCooldown(sys: Sys, rows: HexRow[]): Promise<HexRow[]> {
	const marked: HexRow[] = [];
	for (const row of rows) {
		if (row.status !== "not") {
			marked.push(row);
			continue;
		}
		const ran = await hexPackage(sys, row.name);
		const at = ran.code === 0 ? publishedAt(ran.stdout, row.latest) : chomp(ran.stderr) || `curl exited ${ran.code}`;
		if (typeof at === "string") {
			const message = `could not read when hex.pm published ${row.name} ${row.latest} — cannot check Hex deps: ${at}`;
			sys.err(`${sys.prefix} ${message}`);
			throw new Failed(message);
		}
		marked.push({ ...row, status: sys.now() - at.getTime() < DAY_MS ? "cooldown" : "not" });
	}
	return marked;
}

// hexOutdated: the `mix hex.outdated` report and its rows.
export async function hexOutdated(sys: Sys): Promise<{ report: string; rows: HexRow[] }> {
	// hex.outdated exits 1 when updates exist.
	const ran = await sys.run(["mix", "hex.outdated"]);
	const report = chomp(ran.stdout + ran.stderr);
	const rows = ran.code > 1 ? null : parseHexOutdated(report);
	if (!rows) {
		sys.out(report);
		fail(sys, `mix hex.outdated produced no readable dependency table (exit ${ran.code}) — cannot check Hex deps.`);
	}
	return { report, rows: await markCooldown(sys, rows) };
}

// status SCRIPT SYS: SCRIPT's exit status on SYS, its Failed code when it fails.
export async function status(script: (sys: Sys) => Promise<number>, sys: Sys): Promise<number> {
	try {
		return await script(sys);
	} catch (e) {
		if (!(e instanceof Failed)) throw e;
		return e.code;
	}
}

// main SCRIPT: runs SCRIPT with the real Sys and exits with its status.
export async function main(prefix: string, script: (sys: Sys) => Promise<number>) {
	process.exit(await status(script, realSys(prefix)));
}

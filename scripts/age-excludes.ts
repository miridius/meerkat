// pnpm checks every lockfile entry against minimumReleaseAge, so a release
// under 24h old taken for an advisory (scripts/advisory-fixes.ts, and
// scripts/toolchain.ts for the pnpm pin) stays locked only through an
// exact `name@version` entry in pnpm-workspace.yaml's
// minimumReleaseAgeExclude. Once that release is 24h old, its entry is
// stale.
//
//   bun scripts/age-excludes.ts prune   drops each stale entry
//                                       (scripts/bump-deps.ts)
//   bun scripts/age-excludes.ts check   lists each stale entry and exits 1
//                                       if any (scripts/outdated.ts)
//
// Both exit 2, saying why, when an entry is not an exact name@version or
// its publish time cannot be read.

import { readFileSync, writeFileSync } from "node:fs";
import { stripVTControlCharacters } from "node:util";

export const WORKSPACE = "pnpm-workspace.yaml";
const DAY_MS = 86_400_000;
const COMMENT =
	"# Releases under 24h old taken to fix an advisory; scripts/age-excludes.ts\n# drops each once it is 24h old.\n";
const BLOCK =
	/^(?:# Releases under 24h old taken[^\n]*\n# drops each[^\n]*\n)?minimumReleaseAgeExclude:\n(?: {2}- [^\n]*(?:\n|$))*/m;

export function readExcludes(text = readFileSync(WORKSPACE, "utf8")): string[] {
	const m = text.match(/^minimumReleaseAgeExclude:\n((?: {2}- [^\n]*(?:\n|$))*)/m);
	if (!m) return [];
	return m[1]
		.split("\n")
		.filter(Boolean)
		.map((line) => line.replace(/^ {2}- /, "").replace(/^"(.*)"$/, "$1"));
}

// withExcludes TEXT ENTRIES: the workspace TEXT with ENTRIES as its whole
// minimumReleaseAgeExclude, or none when ENTRIES is empty.
export function withExcludes(text: string, entries: string[]): string {
	const rest = `${text.replace(BLOCK, "").trimEnd()}\n`;
	if (entries.length === 0) return rest;
	const list = [...new Set(entries)].map((e) => `  - ${JSON.stringify(e)}\n`).join("");
	return `${rest}\n${COMMENT}minimumReleaseAgeExclude:\n${list}`;
}

// youngIn OUTPUT: the `name@version`s pnpm's OUTPUT refuses as under
// minimumReleaseAge. pnpm lists each as "name@version was published at
// <date>, within the minimumReleaseAge cutoff", in colour and wrapped to
// the terminal width.
export function youngIn(output: string): string[] {
	const plain = stripVTControlCharacters(output).replace(/\s+/g, " ");
	return [...plain.matchAll(/((?:@[\w.-]+\/)?[\w.-]+@\d\S*) was published at/g)].map((m) => m[1]);
}

// A failure to report: untilAccepted throws it, as does advisory-fixes.ts.
export class Refusal extends Error {}

// What a command ended with.
export type Ran = { code: number; out: string; err: string };

// What untilAccepted, and advisory-fixes.ts, run commands and write files
// with; their bun tests pass a stand-in.
export type Runner = {
	run: (cmd: string[], env?: Record<string, string>) => Ran;
	write: (path: string, body: string) => void;
};

export const system: Runner = {
	run: (cmd, env = {}) => {
		const p = Bun.spawnSync(cmd, { env: { ...process.env, ...env }, stdout: "pipe", stderr: "pipe" });
		return { code: p.exitCode ?? 1, out: p.stdout.toString(), err: p.stderr.toString() };
	},
	write: writeFileSync,
};

// untilAccepted CMD TEXT EXCLUDES: runs CMD with the workspace file
// written as TEXT excluding EXCLUDES and each version CMD refuses as under
// minimumReleaseAge, adding those a round at a time, and returns the
// versions it added. It leaves the file as last written, and gives up
// after 20 rounds.
export function untilAccepted(cmd: string[], text: string, excludes: string[], sys = system): string[] {
	const added: string[] = [];
	for (let round = 0; round < 20; round++) {
		sys.write(WORKSPACE, withExcludes(text, [...excludes, ...added]));
		const r = sys.run(cmd);
		const output = `${r.out}${r.err}`;
		if (r.code === 0) return added;
		const young = youngIn(output).filter((v) => !excludes.includes(v) && !added.includes(v));
		if (young.length === 0) throw new Refusal(`${cmd.join(" ")} failed:\n${output}`);
		added.push(...young);
	}
	throw new Refusal(`${cmd.join(" ")} kept refusing young versions: ${added.join(", ")}`);
}

class Unreadable extends Error {}

// published ENTRY RUN: when the registry published ENTRY, an exact
// name@version, as `pnpm view`, run by RUN, lists its package's times.
export function published(entry: string, run = system.run): Date {
	const at = entry.lastIndexOf("@");
	const [name, version] = [entry.slice(0, at), entry.slice(at + 1)];
	if (at <= 0 || !/^\d/.test(version))
		throw new Unreadable(`${entry} is not an exact name@version entry`);
	const view = run(["pnpm", "view", name, "time", "--json"]);
	const why = (reason: string) =>
		new Unreadable(`could not read when the registry published ${entry}: ${reason}`);
	if (view.code !== 0) throw why(`pnpm view exited ${view.code}:\n${view.err.trim()}`);
	let times: Record<string, string>;
	try {
		times = JSON.parse(view.out);
	} catch (e) {
		throw why(`pnpm view printed no JSON (${e instanceof Error ? e.message : e})`);
	}
	const date = new Date(String(times?.[version]));
	if (Number.isNaN(date.getTime())) throw why(`the registry lists no publish time for ${version}`);
	return date;
}

// stale ENTRIES AT RUN: the ENTRIES 24h old at time AT.
export function stale(entries: string[], at: number, run?: Runner["run"]): string[] {
	return entries.filter((e) => at - published(e, run).getTime() >= DAY_MS);
}

function main(mode: string): number {
	if (mode !== "prune" && mode !== "check") {
		console.error("usage: bun scripts/age-excludes.ts prune|check");
		return 2;
	}
	const prefix = mode === "prune" ? "pre-commit: " : "";
	const text = readFileSync(WORKSPACE, "utf8");
	const entries = readExcludes(text);
	let old: string[];
	try {
		old = stale(entries, Date.now());
	} catch (e) {
		if (!(e instanceof Unreadable)) throw e;
		console.error(`${prefix}scripts/age-excludes.ts: ${e.message} — cannot check minimumReleaseAgeExclude.`);
		return 2;
	}
	if (mode === "check") {
		for (const e of old)
			console.log(`BLOCKED: ${WORKSPACE} excludes ${e} from minimumReleaseAge, but it is 24h old; commit to drop it`);
		return old.length > 0 ? 1 : 0;
	}
	if (old.length > 0) {
		writeFileSync(WORKSPACE, withExcludes(text, entries.filter((e) => !old.includes(e))));
		for (const e of old) console.log(`${prefix}${e} is 24h old; dropped from minimumReleaseAgeExclude.`);
	}
	return 0;
}

if (import.meta.main) process.exit(main(process.argv[2] ?? ""));

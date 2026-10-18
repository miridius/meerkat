// pnpm checks every lockfile entry against minimumReleaseAge, so a release
// under 24h old taken for an advisory (scripts/advisory-fixes.ts, and
// scripts/toolchain.ts for the pnpm pin) stays locked only through an
// exact `name@version` entry in pnpm-workspace.yaml's
// minimumReleaseAgeExclude. Once that release is 24h old, its entry is
// stale.
//
//   bun scripts/age-excludes.ts prune   drops each stale entry
//                                       (scripts/bump-deps.sh)
//   bun scripts/age-excludes.ts check   lists each stale entry and exits 1
//                                       if any (scripts/outdated.sh)
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

// Thrown when untilAccepted's command fails.
export class Refusal extends Error {}

// untilAccepted CMD WORKSPACE EXCLUDES: runs CMD with the workspace TEXT
// WORKSPACE excluding EXCLUDES and each version CMD refuses as under
// minimumReleaseAge, adding those a round at a time, and returns the
// versions it added. The rounds are bounded by the packages CMD pulls in.
export function untilAccepted(cmd: string[], workspace: string, excludes: string[]): string[] {
	const added: string[] = [];
	for (let round = 0; round < 20; round++) {
		writeFileSync(WORKSPACE, withExcludes(workspace, [...excludes, ...added]));
		const r = Bun.spawnSync(cmd, { stdout: "pipe", stderr: "pipe" });
		const output = `${r.stdout.toString()}${r.stderr.toString()}`;
		if (r.exitCode === 0) return added;
		const young = youngIn(output).filter((v) => !excludes.includes(v) && !added.includes(v));
		if (young.length === 0) throw new Refusal(`${cmd.join(" ")} failed:\n${output}`);
		added.push(...young);
	}
	throw new Refusal(`${cmd.join(" ")} kept refusing young versions: ${added.join(", ")}`);
}

class Unreadable extends Error {}

function published(entry: string): Date {
	const at = entry.lastIndexOf("@");
	const [name, version] = [entry.slice(0, at), entry.slice(at + 1)];
	if (at <= 0 || !/^\d/.test(version))
		throw new Unreadable(`${entry} is not an exact name@version entry`);
	const view = Bun.spawnSync(["pnpm", "view", name, "time", "--json"], {
		stdout: "pipe",
		stderr: "pipe",
	});
	let times: Record<string, string> = {};
	try {
		if (view.exitCode === 0) times = JSON.parse(view.stdout.toString());
	} catch {}
	const date = new Date(String(times[version]));
	if (Number.isNaN(date.getTime()))
		throw new Unreadable(
			`could not read when the registry published ${entry} (pnpm view exit ${view.exitCode}):\n${view.stderr.toString().trim()}`,
		);
	return date;
}

function main(mode: string): number {
	if (mode !== "prune" && mode !== "check") {
		console.error("usage: bun scripts/age-excludes.ts prune|check");
		return 2;
	}
	const prefix = mode === "prune" ? "pre-commit: " : "";
	const text = readFileSync(WORKSPACE, "utf8");
	const entries = readExcludes(text);
	let stale: string[];
	try {
		stale = entries.filter((e) => Date.now() - published(e).getTime() >= DAY_MS);
	} catch (e) {
		if (!(e instanceof Unreadable)) throw e;
		console.error(`${prefix}scripts/age-excludes.ts: ${e.message} — cannot check minimumReleaseAgeExclude.`);
		return 2;
	}
	if (mode === "check") {
		for (const e of stale)
			console.log(`BLOCKED: ${WORKSPACE} excludes ${e} from minimumReleaseAge, but it is 24h old; commit to drop it`);
		return stale.length > 0 ? 1 : 0;
	}
	if (stale.length > 0) {
		writeFileSync(WORKSPACE, withExcludes(text, entries.filter((e) => !stale.includes(e))));
		for (const e of stale) console.log(`${prefix}${e} is 24h old; dropped from minimumReleaseAgeExclude.`);
	}
	return 0;
}

if (import.meta.main) process.exit(main(process.argv[2] ?? ""));

// The pre-commit bump's exception to the 24h release-age floor: a locked
// Hex or JS dependency that an audit finds a published advisory against
// is updated with the floor in force and, when that update needs a
// release under 24h old or the audit still finds it, again with the floor
// lifted for it, so whatever release that update resolves is taken
// however young it is. scripts/bump-deps.ts runs this after its own
// updates; check.ts's audits then confirm the fix.
//
// - JS: each package `pnpm audit` names is updated (`--latest` when a
//   workspace manifest depends on it directly). The floor is lifted with
//   the package in pnpm-workspace.yaml's minimumReleaseAgeExclude, plus
//   each exact version pnpm then refuses as too young for that update,
//   such as a platform build the fix pins. pnpm checks the lockfile
//   against minimumReleaseAge too, so the package's own entry then goes,
//   and each version under 24h old the lockfile now holds keeps an exact
//   entry, which scripts/age-excludes.ts drops once it is 24h old.
// - Hex: the packages `mix hex.audit` lists under Advisories are updated;
//   the floor is lifted with HEX_COOLDOWN=0d, as Hex has no per-package
//   exclude. Hex does not check locked versions against its cooldown.
//
// Exits 1, saying why, when an audit cannot be read or an update fails.
//
// main does its I/O through an Io: scripts/advisory-fixes.test.ts drives
// it with a stand-in, and the ExUnit test stubs pnpm and mix on PATH.

import { readFileSync } from "node:fs";
import { Refusal, type Runner, readExcludes, system, untilAccepted, WORKSPACE, youngIn } from "./age-excludes";

const MANIFESTS = ["package.json", "assets/package.json"];

export type Io = Runner & {
	read: (path: string) => string;
	log: (line: string) => void;
	error: (line: string) => void;
};

// Thrown rather than exiting, so fixJs restores the workspace.
function fail(message: string): never {
	throw new Refusal(message);
}

// jsAdvisories: the packages `pnpm audit` finds advisories against.
function jsAdvisories(io: Io): string[] {
	const audit = io.run(["pnpm", "audit", "--json"]);
	let report: { advisories?: Record<string, { module_name?: string }> };
	try {
		report = JSON.parse(audit.out);
	} catch {
		fail(`pnpm audit produced no JSON report (exit ${audit.code}):\n${audit.err}${audit.out}`);
	}
	if (typeof report?.advisories !== "object")
		fail(`pnpm audit produced no advisories list (exit ${audit.code}).`);
	const names = Object.values(report.advisories).map((a) => a.module_name);
	if (names.some((n) => typeof n !== "string")) fail("pnpm audit named no package for an advisory.");
	return [...new Set(names as string[])];
}

function direct(io: Io, name: string): boolean {
	return MANIFESTS.some((file) => {
		const pkg = JSON.parse(io.read(file));
		return [pkg.dependencies, pkg.devDependencies, pkg.optionalDependencies].some(
			(deps) => deps && name in deps,
		);
	});
}

function fixJs(io: Io, name: string) {
	const workspace = io.read(WORKSPACE);
	const kept = readExcludes(workspace);
	const cmd = ["pnpm", "-r", "update", "--ignore-scripts"];
	if (direct(io, name)) cmd.push("--latest");
	cmd.push(name);
	try {
		// A release 24h old may fix it; only if none does is the floor lifted.
		const floored = io.run(cmd);
		if (floored.code !== 0 && youngIn(`${floored.out}${floored.err}`).length === 0)
			fail(`${cmd.join(" ")} failed:\n${floored.out}${floored.err}`);
		if (floored.code === 0 && !jsAdvisories(io).includes(name)) {
			io.log(`pre-commit: ${name} has an advisory; updated it to a fix 24h old.`);
			return;
		}
		const pulled = untilAccepted(cmd, workspace, [...kept, name], io);
		const young = untilAccepted(
			["pnpm", "install", "--frozen-lockfile", "--ignore-scripts", "--prefer-offline"],
			workspace,
			[...kept, ...pulled],
			io,
		);
		const excluded = [...pulled, ...young];
		const note = excluded.length ? `; excluded ${excluded.join(", ")} until 24h old` : "";
		io.log(`pre-commit: ${name} has an advisory; updated it with the 24h floor lifted${note}.`);
	} catch (e) {
		io.write(WORKSPACE, workspace);
		throw e;
	}
}

// hexAdvisories: the packages `mix hex.audit` lists under Advisories.
function hexAdvisories(io: Io): string[] {
	const audit = io.run(["mix", "hex.audit"]);
	if (audit.err.includes("Failed to fetch record"))
		fail(`Hex could not fetch every package's record:\n${audit.err}`);
	const section = audit.out.split(/^Advisories:$/m)[1];
	if (section === undefined) {
		if (audit.code === 0 || audit.out.includes("Retired packages")) return [];
		fail(`mix hex.audit failed (exit ${audit.code}):\n${audit.err}${audit.out}`);
	}
	// The section ends at the next unindented line, such as a Retired
	// packages heading.
	const advisories = section.replace(/^\n/, "").split(/^\S/m)[0];
	const names = [...advisories.matchAll(/^ {2}(\S+) \S+ - /gm)].map((m) => m[1]);
	if (names.length === 0) fail(`mix hex.audit listed advisories it named no package for:\n${audit.out}`);
	return [...new Set(names)];
}

function hexUpdate(io: Io, names: string[], env: Record<string, string> = {}) {
	const update = io.run(["mix", "deps.update", ...names], env);
	if (update.code !== 0)
		fail(`mix deps.update ${names.join(" ")} failed:\n${update.out}${update.err}`);
}

// A release 24h old may fix each; the cooldown is lifted only for the rest.
function fixHex(io: Io) {
	const hex = hexAdvisories(io);
	if (hex.length === 0) return;
	hexUpdate(io, hex);
	const rest = hexAdvisories(io).filter((n) => hex.includes(n));
	const fixed = hex.filter((n) => !rest.includes(n));
	if (fixed.length) io.log(`pre-commit: ${fixed.join(", ")} had advisories; updated to fixes 24h old.`);
	if (rest.length === 0) return;
	hexUpdate(io, rest, { HEX_COOLDOWN: "0d" });
	io.log(`pre-commit: ${rest.join(", ")} had advisories; updated with the 24h floor lifted.`);
}

// main: the exit status, having fixed what the audits find or, for 1,
// written why it could not.
export function main(io: Io): number {
	try {
		for (const name of jsAdvisories(io)) fixJs(io, name);
		fixHex(io);
		return 0;
	} catch (e) {
		if (!(e instanceof Refusal)) throw e;
		io.error(`pre-commit: ${e.message}`);
		return 1;
	}
}

if (import.meta.main)
	process.exit(main({ ...system, read: (path) => readFileSync(path, "utf8"), log: console.log, error: console.error }));

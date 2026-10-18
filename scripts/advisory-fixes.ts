// The pre-commit bump's exception to the 24h release-age floor: a locked
// Hex or JS dependency that an audit finds a published advisory against
// is updated under the floor and, when that update needs a release under
// 24h old or the audit still finds it, again with the floor lifted for
// it, so whatever release that update resolves is taken however young it
// is. scripts/bump-deps.sh runs this after its own updates; check.sh's
// audits then confirm the fix.
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

import { readFileSync, writeFileSync } from "node:fs";
import { Refusal, readExcludes, untilAccepted, WORKSPACE, youngIn } from "./age-excludes";

const MANIFESTS = ["package.json", "assets/package.json"];

function run(cmd: string[], env: Record<string, string> = {}) {
	const p = Bun.spawnSync(cmd, {
		env: { ...process.env, ...env },
		stdout: "pipe",
		stderr: "pipe",
	});
	return { code: p.exitCode ?? 1, out: p.stdout.toString(), err: p.stderr.toString() };
}

// Thrown rather than exiting, so fixJs restores the workspace.
function fail(message: string): never {
	throw new Refusal(message);
}

// jsAdvisories: the packages `pnpm audit` finds advisories against.
function jsAdvisories(): string[] {
	const audit = run(["pnpm", "audit", "--json"]);
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

function direct(name: string): boolean {
	return MANIFESTS.some((file) => {
		const pkg = JSON.parse(readFileSync(file, "utf8"));
		return [pkg.dependencies, pkg.devDependencies, pkg.optionalDependencies].some(
			(deps) => deps && name in deps,
		);
	});
}

function fixJs(name: string) {
	const workspace = readFileSync(WORKSPACE, "utf8");
	const kept = readExcludes(workspace);
	const cmd = ["pnpm", "-r", "update", "--ignore-scripts"];
	if (direct(name)) cmd.push("--latest");
	cmd.push(name);
	try {
		// A release 24h old may fix it; only if none does is the floor lifted.
		const floored = run(cmd);
		if (floored.code !== 0 && youngIn(`${floored.out}${floored.err}`).length === 0)
			fail(`${cmd.join(" ")} failed:\n${floored.out}${floored.err}`);
		if (floored.code === 0 && !jsAdvisories().includes(name)) {
			console.log(`pre-commit: ${name} has an advisory; updated it to a fix 24h old.`);
			return;
		}
		const pulled = untilAccepted(cmd, workspace, [...kept, name]);
		const young = untilAccepted(
			["pnpm", "install", "--frozen-lockfile", "--ignore-scripts", "--prefer-offline"],
			workspace,
			[...kept, ...pulled],
		);
		const excluded = [...pulled, ...young];
		const note = excluded.length ? `; excluded ${excluded.join(", ")} until 24h old` : "";
		console.log(`pre-commit: ${name} has an advisory; updated it under the 24h floor${note}.`);
	} catch (e) {
		writeFileSync(WORKSPACE, workspace);
		throw e;
	}
}

// hexAdvisories: the packages `mix hex.audit` lists under Advisories.
function hexAdvisories(): string[] {
	const audit = run(["mix", "hex.audit"]);
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

function hexUpdate(names: string[], env: Record<string, string> = {}) {
	const update = run(["mix", "deps.update", ...names], env);
	if (update.code !== 0)
		fail(`mix deps.update ${names.join(" ")} failed:\n${update.out}${update.err}`);
}

// A release 24h old may fix each; the cooldown is lifted only for the rest.
function fixHex() {
	const hex = hexAdvisories();
	if (hex.length === 0) return;
	hexUpdate(hex);
	const rest = hexAdvisories().filter((n) => hex.includes(n));
	const fixed = hex.filter((n) => !rest.includes(n));
	if (fixed.length) console.log(`pre-commit: ${fixed.join(", ")} had advisories; updated to fixes 24h old.`);
	if (rest.length === 0) return;
	hexUpdate(rest, { HEX_COOLDOWN: "0d" });
	console.log(`pre-commit: ${rest.join(", ")} had advisories; updated under the 24h floor.`);
}

try {
	for (const name of jsAdvisories()) fixJs(name);
	fixHex();
} catch (e) {
	if (!(e instanceof Refusal)) throw e;
	console.error(`pre-commit: ${e.message}`);
	process.exit(1);
}

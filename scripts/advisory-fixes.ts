// The pre-commit bump's exception to the 24h release-age floor: a locked
// Hex or JS dependency that an audit finds a published advisory against
// is updated with the floor lifted for it, so a release that fixes the
// advisory is taken however young it is. scripts/bump-deps.sh runs this
// after its own updates; check.sh's audits then confirm the fix.
//
// - JS: each package `pnpm audit` names is updated (`--latest` when a
//   workspace manifest depends on it directly) with the package in
//   pnpm-workspace.yaml's minimumReleaseAgeExclude, plus each exact
//   version pnpm then refuses as too young for that update, such as a
//   platform build the fix pins. The workspace file is restored after.
// - Hex: the packages `mix hex.audit` lists under Advisories are updated
//   with HEX_COOLDOWN=0d, as Hex has no per-package exclude.
//
// Exits 1, saying why, when an audit cannot be read or an update fails.

import { readFileSync, writeFileSync } from "node:fs";

const WORKSPACE = "pnpm-workspace.yaml";
const MANIFESTS = ["package.json", "assets/package.json"];

function run(cmd: string[], env: Record<string, string> = {}) {
	const p = Bun.spawnSync(cmd, {
		env: { ...process.env, ...env },
		stdout: "pipe",
		stderr: "pipe",
	});
	return { code: p.exitCode ?? 1, out: p.stdout.toString(), err: p.stderr.toString() };
}

// Thrown rather than exiting, so fixJs's finally restores the workspace.
class Refusal extends Error {}

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
	if (/^minimumReleaseAgeExclude:/m.test(workspace))
		fail(`${WORKSPACE} already sets minimumReleaseAgeExclude; cannot lift the floor for ${name}.`);
	const excluded = [name];
	const cmd = ["pnpm", "-r", "update", "--ignore-scripts"];
	if (direct(name)) cmd.push("--latest");
	cmd.push(name);
	try {
		// Each round lets one more exact version through, so the number of
		// rounds is bounded by the packages the fix pulls in.
		for (let round = 0; round < 20; round++) {
			writeFileSync(
				WORKSPACE,
				`${workspace.trimEnd()}\n\nminimumReleaseAgeExclude:\n${excluded
					.map((e) => `  - ${JSON.stringify(e)}\n`)
					.join("")}`,
			);
			const update = run(cmd);
			if (update.code === 0) {
				console.log(`pre-commit: ${name} has an advisory; updated it under the 24h floor.`);
				return;
			}
			const young = `${update.out}${update.err}`.match(
				/Version (\S+) \(released [^)]*\) of (\S+) does not meet the minimumReleaseAge/,
			);
			if (!young || excluded.includes(`${young[2]}@${young[1]}`))
				fail(`${cmd.join(" ")} failed:\n${update.out}${update.err}`);
			excluded.push(`${young[2]}@${young[1]}`);
		}
		fail(`${cmd.join(" ")} kept refusing young versions: ${excluded.join(", ")}`);
	} finally {
		writeFileSync(WORKSPACE, workspace);
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

function fixHex() {
	const hex = hexAdvisories();
	if (hex.length === 0) return;
	const update = run(["mix", "deps.update", ...hex], { HEX_COOLDOWN: "0d" });
	if (update.code !== 0)
		fail(`mix deps.update ${hex.join(" ")} failed:\n${update.out}${update.err}`);
	console.log(`pre-commit: ${hex.join(", ")} had advisories; updated under the 24h floor.`);
}

try {
	for (const name of jsAdvisories()) fixJs(name);
	fixHex();
} catch (e) {
	if (!(e instanceof Refusal)) throw e;
	console.error(`pre-commit: ${e.message}`);
	process.exit(1);
}

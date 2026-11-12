// Pre-commit, and post-rewrite through scripts/rebase-bump.ts: moves each
// direct Hex and JS dependency that scripts/outdated.ts would report to its
// latest release, and stages the dependency files the bump changed into the
// commit. Packages that are current are left alone, so a commit carries no
// dependency change when nothing is behind.
//
// - Hex: a release outside mix.exs's requirement gets a new requirement
//   (scripts/bump-hex-requirements.exs); then `mix deps.update`. A
//   release another dependency holds back stays behind, and the pre-push
//   gate reports it. A release younger than the 24h Hex cooldown mix.exs
//   sets is skipped.
// - JS: `pnpm -r update --latest`, which rewrites the package.json range
//   and keeps pnpm-workspace.yaml's minimumReleaseAge, so no release
//   younger than 24h enters the lockfile. A release that requires a
//   package version younger than that is skipped, since pnpm refuses it.
// - Advisories: scripts/age-excludes.ts drops each minimumReleaseAgeExclude
//   entry that is now 24h old. Then scripts/advisory-fixes.ts updates each
//   locked Hex or JS dependency an audit finds an advisory against, first
//   with the 24h floor in force and, when that does not fix it, with the
//   floor lifted for it.
// - Toolchain: scripts/toolchain.ts moves the pins in
//   .tool-versions, .github/toolchain.env, package.json's packageManager and the
//   actions that the workflows and .github/actions/toolchain use onto their
//   targets. Then scripts/setup-toolchain.ts installs any pinned Hex or
//   rebar3 still missing, and with mise any pinned Erlang, Elixir or Bun,
//   so the checks do not run without them.
//
// A package whose latest release is the one its scripts/dep-exemptions.json
// entry names is left where it is; for JS, that is either the latest
// release past the 24h floor or the registry's latest. Before its
// reports, it installs the locked dependencies, refusing the commit when
// that would change mix.lock or pnpm-lock.yaml. Any failure refuses the
// commit, or, after a rebase, leaves the rebase without a bump commit.
//
//   bun scripts/bump-deps.ts

import { basename } from "node:path";
import {
	Failed,
	hexOutdated,
	loadExemptions,
	main,
	npmLatest,
	pnpmInstallable,
	pnpmOutdated,
	requireTools,
	type Sys,
	syncLockedDeps,
} from "./deps-common.ts";

const FILES = [
	"mix.exs",
	"mix.lock",
	"package.json",
	"pnpm-lock.yaml",
	"assets/package.json",
	"pnpm-workspace.yaml",
	".tool-versions",
	".github/toolchain.env",
	".github/workflows/ci.yml",
	".github/workflows/audit.yml",
	".github/actions/toolchain/action.yml",
];

// isPathCommit INDEX: whether Git's GIT_INDEX_FILE INDEX is the temporary
// index of a path commit (`git commit <path>`) rather than the real one,
// which `git commit -a` exports as index.lock.
export function isPathCommit(index: string | undefined): boolean {
	return !["index", "index.lock"].includes(basename(index ?? "index"));
}

async function hashes(sys: Sys): Promise<string[]> {
	return Promise.all(FILES.map(async (file) => (await sys.run(["git", "hash-object", "--", file])).stdout.trim()));
}

// step CMD: runs CMD, streaming its output; its failure fails the bump
// with CMD's exit status.
async function step(sys: Sys, cmd: string[]) {
	const { code } = await sys.run(cmd, { inherit: true });
	if (code !== 0) throw new Failed(`${cmd.join(" ")} exited ${code}`, code);
}

export async function bumpDeps(sys: Sys): Promise<number> {
	// A path commit commits from a temporary index, so a bump staged there
	// would be missing from the real index afterwards, which would then
	// hold its revert.
	if (isPathCommit(sys.env.GIT_INDEX_FILE)) {
		sys.out("pre-commit: path commit; dependency bump deferred to the next full commit.");
		return 0;
	}

	requireTools(sys, "mix", "elixir", "pnpm", "curl");
	const exemptions = loadExemptions(sys);
	// An entry covers one release; a newer release is bumped to.
	const isExempt = (name: string, version: string) =>
		Object.hasOwn(exemptions, name) && exemptions[name].version === version;

	const before = await hashes(sys);

	await syncLockedDeps(sys);
	const hexNames: string[] = [];
	const requirementBumps: string[] = [];
	for (const { name, latest, status } of (await hexOutdated(sys)).rows) {
		if (status === "cooldown" || isExempt(name, latest)) continue;
		hexNames.push(name);
		if (status === "not") requirementBumps.push(name, latest);
	}

	const mixExs = (await sys.run(["git", "hash-object", "-w", "--", "mix.exs"])).stdout.trim();
	if (requirementBumps.length) await step(sys, ["elixir", "scripts/bump-hex-requirements.exs", ...requirementBumps]);
	if (hexNames.length && (await sys.run(["mix", "deps.update", ...hexNames], { inherit: true })).code !== 0) {
		// A rewritten requirement left behind would be committed alone.
		sys.write("mix.exs", (await sys.run(["git", "cat-file", "blob", mixExs])).stdout);
		sys.out(`pre-commit: mix deps.update ${hexNames.join(" ")} failed, so the commit was refused.`);
		sys.out("  If Hex lists versions filtered by cooldown above, a release needs a");
		sys.out("  dependency version still under the 24h Hex cooldown. Wait until it is");
		sys.out("  eligible, or exempt it in scripts/dep-exemptions.json.");
		return 1;
	}

	const jsNames: string[] = [];
	for (const { name, latest } of await pnpmOutdated(sys)) {
		if (isExempt(name, latest)) continue;
		// An entry naming a release younger than the 24h floor holds the
		// package where it is, rather than bumping it to an older release.
		if (Object.hasOwn(exemptions, name) && isExempt(name, await npmLatest(sys, name))) continue;
		if ((await pnpmInstallable(sys, name)) === "young") {
			sys.out(`pre-commit: ${name}@${latest} requires a package version under the 24h floor; not bumped yet.`);
			continue;
		}
		jsNames.push(name);
	}
	if (jsNames.length) await step(sys, ["pnpm", "-r", "update", "--latest", "--ignore-scripts", ...jsNames]);

	await step(sys, ["bun", "scripts/age-excludes.ts", "prune"]);
	await step(sys, ["bun", "scripts/advisory-fixes.ts"]);
	await step(sys, ["bun", "scripts/toolchain.ts", "bump"]);
	await step(sys, ["bun", "scripts/setup-toolchain.ts"]);

	const after = await hashes(sys);
	const bumped = FILES.filter((_, i) => after[i] !== before[i]);
	if (bumped.length) {
		await step(sys, ["git", "diff", "--stat", "--", ...bumped]);
		await step(sys, ["git", "add", "--", ...bumped]);
		sys.out("pre-commit: staged the dependency bump into this commit.");
	}
	return 0;
}

if (import.meta.main) {
	const top = Bun.spawnSync(["git", "rev-parse", "--show-toplevel"]);
	if (top.exitCode !== 0) process.exit(top.exitCode);
	process.chdir(top.stdout.toString().trim());
	await main("pre-commit:", bumpDeps);
}

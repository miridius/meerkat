// Dependency gate: pre-push fails while any JS or Hex dependency is
// behind its latest release, except exempted releases and releases too
// young to install under the 24h supply-chain floor, so not yet
// actionable: JS releases that are, or require a package version that
// is, younger than minimumReleaseAge in pnpm-workspace.yaml, and Hex
// releases younger than the cooldown in mix.exs. A too-young release
// still makes an exemption for an older one stale. A git dependency
// whose pinned GitHub commit contains the tag of its newest stable Hex
// release at least 24h old, in the GitHub repo Hex links, counts as that
// release; the gate fails on every other git dependency, exempt or not.
// The gate also fails on a missing or malformed
// scripts/dep-exemptions.json or a stale entry there, on a toolchain pin
// off its target (scripts/toolchain.ts), on a minimumReleaseAgeExclude
// entry 24h old (scripts/age-excludes.ts), and when installing
// the locked dependencies would change mix.lock or pnpm-lock.yaml. It
// fails CLOSED on its own breakage: missing tools, unreachable
// registries, unparseable probe output, or a pnpm resolution that fails
// for another reason block the push rather than skipping a check.
//
//   bun scripts/outdated.ts

import { join } from "node:path";
import {
	DAY_MS,
	type Exemptions,
	fail,
	hexOutdated,
	hexPackage,
	loadExemptions,
	main,
	pnpmInstallable,
	pnpmOutdated,
	requireTools,
	type Sys,
	syncLockedDeps,
} from "./deps-common.ts";

const PREFIX = "scripts/outdated.ts:";

// gitDepNames LOCK: the packages mix.lock's text LOCK takes from git.
export function gitDepNames(lock: string): string[] {
	return [...lock.matchAll(/^ {2}"([a-z0-9_]+)": \{:git,/gm)].map((m) => m[1]);
}

// lockPin LOCK NAME: the GitHub owner, repo and commit mix.lock's text
// LOCK pins NAME to, or null when it pins NAME to no https://github.com
// commit.
export function lockPin(lock: string, name: string): { repo: string; sha: string } | null {
	for (const line of lock.split("\n")) {
		if (!line.startsWith(`  "${name}": {:git, `)) continue;
		const m = line.match(/^ {2}"[^"]+": \{:git, "https:\/\/github\.com\/([^/"]+)\/([^/"]+)", "([0-9a-f]{7,40})"/);
		if (m) return { repo: `${m[1]}:${m[2].replace(/\.git$/, "")}`, sha: m[3] };
	}
	return null;
}

type HexRecord = {
	releases?: { version?: unknown; inserted_at?: unknown }[];
	meta?: { links?: Record<string, unknown> | null };
};

// matureStable RECORD NOW: the newest stable release in hex.pm's RECORD
// published at least 24h before NOW, or null. hex.pm lists releases newest
// version first.
export function matureStable(record: HexRecord, now: number): string | null {
	if (!Array.isArray(record?.releases)) return null;
	for (const release of record.releases) {
		const { version, inserted_at: at } = release ?? {};
		if (typeof version !== "string") return null;
		if (version.includes("-")) continue;
		if (typeof at !== "string" || !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z$/.test(at)) return null;
		if (Date.parse(at.replace(/\.\d+Z$/, "Z")) <= now - DAY_MS) return version;
	}
	return null;
}

// hexUpstream RECORD: the owner/repo of the GitHub repo hex.pm's RECORD
// links, preferring its GitHub link, then Source, then any other.
export function hexUpstream(record: HexRecord): string | null {
	const links = record?.meta?.links ?? {};
	for (const link of [links.GitHub, links.Source, ...Object.values(links)]) {
		const m = typeof link === "string" ? link.match(/^https:\/\/github\.com\/([^/#?]+\/[^/#?]+)/) : null;
		if (m) return m[1].replace(/\.git$/, "");
	}
	return null;
}

// pinContains NAME VERSION RECORD: whether the GitHub commit mix.lock pins
// NAME to contains VERSION's tag (vVERSION or VERSION) in the GitHub repo
// hex.pm's RECORD links, per GitHub's compare API. An exemption naming a
// release the pin lacks would claim fixes the project does not have.
// Requests carry GITHUB_TOKEN, or else gh's token, when there is one:
// unauthenticated callers share 60 requests an hour per IP.
async function pinContains(sys: Sys, lock: string, name: string, version: string, record: HexRecord) {
	const pin = lockPin(lock, name);
	if (!pin) {
		sys.out(
			`BLOCKED: ${name} — mix.lock pins it to no https://github.com commit, so its pin cannot be checked against ${version}; failing closed`,
		);
		return false;
	}
	const upstream = hexUpstream(record);
	if (!upstream) {
		sys.out(`BLOCKED: ${name} — Hex links no GitHub repo to find release ${version} in; failing closed`);
		return false;
	}
	let token = sys.env.GITHUB_TOKEN;
	if (!token) token = (await sys.run(["gh", "auth", "token"]).catch(() => ({ stdout: "" }))).stdout.trim();
	// The token goes in a curl config on stdin, kept out of the process list.
	const auth = token ? `header = "Authorization: Bearer ${token}"\n` : "\n";
	for (const tag of [`v${version}`, version]) {
		const url = `https://api.github.com/repos/${upstream}/compare/${tag}...${pin.repo}:${pin.sha}`;
		// -L follows GitHub's redirect for a renamed repo.
		const ran = await sys.run(["curl", "-sSL", "--max-time", "10", "-K", "-", "-w", "\n%{http_code}", url], {
			stdin: auth,
		});
		if (ran.stderr) sys.err(ran.stderr.replace(/\n$/, ""));
		if (ran.code !== 0) {
			sys.out(`BLOCKED: ${name} — could not reach GitHub to compare its pin with ${upstream} ${tag}; failing closed`);
			return false;
		}
		const cut = ran.stdout.lastIndexOf("\n");
		const [body, code] = [ran.stdout.slice(0, cut), ran.stdout.slice(cut + 1)];
		// 404: no such tag (or commit); try the other tag spelling.
		if (code === "404") continue;
		if (code !== "200") {
			sys.out(`BLOCKED: ${name} — GitHub answered HTTP ${code} comparing its pin with ${upstream} ${tag}; failing closed`);
			if (code === "403" || code === "429") sys.out("  GitHub may be rate-limiting; set GITHUB_TOKEN or log in with gh");
			return false;
		}
		let status: unknown;
		try {
			status = JSON.parse(body)?.status;
		} catch {}
		if (status === undefined || status === null || status === false) {
			sys.out(`BLOCKED: ${name} — could not read GitHub's comparison of its pin with ${upstream} ${tag}; failing closed`);
			return false;
		}
		if (status === "ahead" || status === "identical") {
			sys.out(`current: ${name} is pinned to ${pin.sha}, which contains ${upstream} ${tag}`);
			return true;
		}
		sys.out(`BLOCKED: ${name} is pinned to ${pin.sha}, which does not contain ${upstream} ${tag};`);
		sys.out(`  move the pin onto a commit that contains ${version}, or depend on the Hex release`);
		return false;
	}
	sys.out(
		`BLOCKED: ${name} — GitHub finds neither tag v${version} nor ${version} in ${upstream}, or not pin ${pin.sha}; failing closed`,
	);
	return false;
}

export async function outdated(sys: Sys): Promise<number> {
	requireTools(sys, "pnpm", "mix", "curl");

	// An entry applies to both ecosystems, and scripts/bump-deps.ts skips
	// the same releases. Once a newer release is out, or the package is
	// current, the entry is stale and fails the gate.
	const exemptions: Exemptions = loadExemptions(sys);

	let failed = false;
	// Exemption entries whose package is behind, whether or not the entry
	// names its latest release; any other entry is for a current package.
	const matched = new Set<string>();

	// exempt NAME LATEST: whether an entry covers exactly LATEST. An entry
	// for any other release is stale and fails the gate, even when LATEST
	// is too young to require; the caller then checks the package as if
	// unexempted.
	const exempt = (name: string, latest: string) => {
		const entry = Object.hasOwn(exemptions, name) ? exemptions[name] : undefined;
		if (!entry) return false;
		matched.add(name);
		if (entry.version !== latest) {
			sys.out(`stale exemption: ${name} covers ${entry.version}, but latest is ${latest}`);
			failed = true;
			return false;
		}
		sys.out(`exempt: ${name}@${latest} (${entry.reason})`);
		return true;
	};

	for (const registry of ["https://registry.npmjs.org", "https://hex.pm"]) {
		if ((await sys.run(["curl", "-sf", "--max-time", "5", registry])).code !== 0)
			fail(sys, `${registry} unreachable — cannot verify dependencies are current.`);
	}

	await syncLockedDeps(sys);

	sys.out("=== pnpm outdated (workspace) ===");
	// An entry must name the registry's latest. pnpm's latest lags a release
	// younger than the 24h floor, and pnpm leaves out a package installed at
	// the newest release past the floor, so entries are checked against a
	// report without the floor.
	const exempted = new Set<string>();
	for (const { name, latest } of await pnpmOutdated(sys, "--config.minimum-release-age=0"))
		if (exempt(name, latest)) exempted.add(name);
	// With the floor, pnpm reports only releases past it, so a release under
	// 24h never blocks.
	for (const { name, latest } of await pnpmOutdated(sys)) {
		if (exempted.has(name)) continue;
		// pnpm outdated still reports a release past the floor that requires
		// a package version under it, which pnpm refuses to install.
		if ((await pnpmInstallable(sys, name)) === "young") {
			sys.out(`too young: ${name}@${latest} requires a package version under the 24h floor`);
			continue;
		}
		sys.out(`BLOCKED: ${name} is outdated (latest: ${latest})`);
		failed = true;
	}

	sys.out("");
	sys.out("=== mix hex.outdated ===");
	const hex = await hexOutdated(sys);
	sys.out(hex.report);
	for (const { name, latest, status } of hex.rows) {
		if (exempt(name, latest)) continue;
		if (status === "cooldown") {
			sys.out(`too young: ${name}@${latest} is under the 24h Hex cooldown`);
			continue;
		}
		sys.out(`BLOCKED: ${name} is outdated (latest: ${latest})`);
		failed = true;
	}

	// A git dependency is absent from hex.outdated's table, so nothing above
	// would notice the Hex release that makes its pin unnecessary. A pin
	// that contains the newest stable Hex release at least 24h old
	// (pinContains) is current; any other blocks, exempt or not.
	// scripts/bump-deps.ts never moves a git dependency, so its pin is moved
	// by hand.
	sys.out("");
	sys.out("=== git dependencies ===");
	const lock = sys.read("mix.lock");
	if (lock === null) fail(sys, "could not read mix.lock — cannot check git deps.");
	for (const name of gitDepNames(lock)) {
		const ran = await hexPackage(sys, name);
		if (ran.stderr) sys.err(ran.stderr.replace(/\n$/, ""));
		let record: HexRecord | null = null;
		try {
			record = ran.code === 0 ? JSON.parse(ran.stdout) : null;
		} catch {}
		const latest = record && matureStable(record, sys.now());
		if (!record || !latest) {
			sys.out(`BLOCKED: ${name} — no stable Hex release at least 24h old found for this git dependency; failing closed`);
			// Its entry was not checked, so it is not stale.
			matched.add(name);
			failed = true;
			continue;
		}
		if (await pinContains(sys, lock, name, latest, record)) continue;
		// The pin is behind, or not checked, so its entry is not stale.
		matched.add(name);
		failed = true;
	}

	// The toolchain is pinned outside the lockfiles, to the same floor. A
	// young release let in for an advisory stays excluded only until 24h
	// old.
	sys.out("");
	sys.out("=== toolchain ===");
	for (const check of [
		["bun", "scripts/toolchain.ts", "check"],
		["bun", "scripts/age-excludes.ts", "check"],
	]) {
		const { code } = await sys.run(check, { inherit: true });
		if (code > 1) return 1;
		if (code !== 0) failed = true;
	}

	for (const name of Object.keys(exemptions).sort()) {
		if (!matched.has(name)) {
			sys.out(`stale exemption: ${name} is not behind latest; remove its entry`);
			failed = true;
		}
	}

	if (failed) {
		sys.out("");
		sys.out(`${PREFIX} dependencies are behind latest, or an exemption`);
		sys.out("is stale. Upgrade them and fix the fallout.");
		return 1;
	}

	sys.out("");
	sys.out("all dependencies current.");
	return 0;
}

if (import.meta.main) {
	process.chdir(join(import.meta.dir, ".."));
	await main(PREFIX, outdated);
}

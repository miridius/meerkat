// Drives scripts/advisory-fixes.ts's main through a stand-in Io, whose
// pnpm and mix answer as each test sets up and log each run. pnpm's update
// refuses each version in `young` until the workspace excludes it, and the
// frozen install each in `lockedYoung` the same way. The ExUnit test
// test/scripts/advisory_fixes_test.exs covers the seams: pnpm, mix and the
// workspace file on disk.
import { beforeEach, expect, test } from "bun:test";
import type { Ran } from "./age-excludes";
import { main } from "./advisory-fixes";

const WORKSPACE = "packages:\n  - assets\nminimumReleaseAge: 1440\n";
const CLEAN_HEX = "No retired or vulnerable packages found.\n";

let files: Map<string, string>;
let log: string[];
let out: string[];
// The workspace the last `pnpm -r update` saw.
let seen: string;
let world: {
	audit: string;
	hexAudit: string;
	hexCode: number;
	hexErr: string;
	young: string[];
	lockedYoung: string[];
	// A release 24h old fixes the advisory.
	floorFixes: boolean;
	failUpdate: boolean;
	failInstall: boolean;
	failHexUpdate: boolean;
	// The Hex audit an update with the floor in force leaves.
	hexAfterFloor?: string;
	jsFixed: boolean;
	hexFixed: boolean;
};

const ok = (stdout = ""): Ran => ({ code: 0, out: stdout, err: "" });

// Refuses, as pnpm 12 does, each of YOUNG the workspace does not exclude.
function refuse(young: string[]): Ran | undefined {
	const workspace = files.get("pnpm-workspace.yaml") as string;
	const refused = young.filter((v) => !workspace.includes(`"${v}"`));
	if (refused.length === 0) return undefined;
	const lines = refused.map(
		(v) =>
			`\x1b[31m      \x1b[0m  ${v} was published at 2026-10-\n` +
			"\x1b[31m      \x1b[0m15T13:13:29.674Z, within the minimumReleaseAge cutoff\n",
	);
	return { code: 1, out: `Error: \x1b[31mERR_PNPM_NO_MATURE_MATCHING_VERSION\x1b[0m\n\n${lines.join("")}`, err: "" };
}

function run(cmd: string[], env: Record<string, string> = {}): Ran {
	const line = cmd.join(" ");
	log.push(env.HEX_COOLDOWN ? `${line} HEX_COOLDOWN=${env.HEX_COOLDOWN}` : line);
	if (line === "pnpm audit --json")
		return world.jsFixed ? ok('{"advisories": {}}') : { code: 1, out: world.audit, err: "" };
	if (line.startsWith("pnpm -r update ")) {
		seen = files.get("pnpm-workspace.yaml") as string;
		const refused = refuse(world.young);
		if (refused) return refused;
		if (world.failUpdate) return { code: 1, out: "ERR_PNPM_BROKEN\n", err: "" };
		if (world.floorFixes) world.jsFixed = true;
		return ok();
	}
	if (line === "pnpm install --frozen-lockfile --ignore-scripts --prefer-offline") {
		const refused = refuse(world.lockedYoung);
		if (refused) return refused;
		if (world.failInstall) return { code: 1, out: "ERR_PNPM_BROKEN_INSTALL\n", err: "" };
		return ok();
	}
	if (line === "mix hex.audit") {
		if (world.hexFixed) return ok(CLEAN_HEX);
		return { code: world.hexCode, out: world.hexAudit, err: world.hexErr };
	}
	if (line.startsWith("mix deps.update ")) {
		if (world.failHexUpdate) return { code: 1, out: "ERR_DEPS\n", err: "" };
		if (world.floorFixes) world.hexFixed = true;
		if (!env.HEX_COOLDOWN && world.hexAfterFloor) world.hexAudit = world.hexAfterFloor;
		return ok();
	}
	throw new Error(`unexpected command: ${line}`);
}

function fixes(): { code: number; out: string } {
	out = [];
	const code = main({
		run,
		read: (path) => {
			const text = files.get(path);
			if (text === undefined) throw new Error(`ENOENT ${path}`);
			return text;
		},
		write: (path, body) => {
			files.set(path, body);
		},
		log: (line) => out.push(line),
		error: (line) => out.push(line),
	});
	return { code, out: out.join("\n") };
}

const audit = (names: string[]) =>
	(world.audit = JSON.stringify({
		advisories: Object.fromEntries(names.map((n, i) => [String(i), { module_name: n }])),
	}));
const hexAudit = (text: string) => {
	world.hexAudit = text;
	world.hexCode = 1;
};
const updates = (match: string) => log.filter((l) => l.includes(match));
const workspace = () => files.get("pnpm-workspace.yaml");

beforeEach(() => {
	files = new Map([
		["pnpm-workspace.yaml", WORKSPACE],
		["package.json", '{"devDependencies": {"vite": "^8.0.0"}}'],
		["assets/package.json", '{"dependencies": {"svelte": "^5.0.0"}}'],
	]);
	log = [];
	seen = "";
	world = {
		audit: '{"advisories": {}}',
		hexAudit: CLEAN_HEX,
		hexCode: 0,
		hexErr: "",
		young: [],
		lockedYoung: [],
		floorFixes: false,
		failUpdate: false,
		failInstall: false,
		failHexUpdate: false,
		jsFixed: false,
		hexFixed: false,
	};
});

test("with no advisory nothing is updated", () => {
	expect(fixes()).toEqual({ code: 0, out: "" });
	expect(log).toEqual(["pnpm audit --json", "mix hex.audit"]);
});

test("a direct JS dependency is updated to latest with the floor lifted for it", () => {
	audit(["vite"]);
	const { code, out } = fixes();
	expect(code).toBe(0);
	expect(out).toContain("vite has an advisory; updated it with the 24h floor lifted.");
	expect(log).toContain("pnpm -r update --ignore-scripts --latest vite");
	expect(seen).toContain('minimumReleaseAgeExclude:\n  - "vite"\n');
	// The lockfile holds no young version, so nothing stays excluded.
	expect(workspace()).toBe(WORKSPACE);
});

test("a dependency of the assets workspace counts as direct", () => {
	audit(["svelte"]);
	expect(fixes().code).toBe(0);
	expect(log).toContain("pnpm -r update --ignore-scripts --latest svelte");
});

test("a transitive JS dependency is updated within its ranges, under the floor first", () => {
	audit(["esbuild", "esbuild"]);
	expect(fixes().code).toBe(0);
	expect(updates("update")).toEqual([
		"pnpm -r update --ignore-scripts esbuild",
		"pnpm -r update --ignore-scripts esbuild",
	]);
});

test("a JS fix 24h old is taken without lifting the floor", () => {
	audit(["vite"]);
	world.floorFixes = true;
	const { code, out } = fixes();
	expect(code).toBe(0);
	expect(out).toContain("vite has an advisory; updated it to a fix 24h old.");
	expect(updates("update")).toEqual(["pnpm -r update --ignore-scripts --latest vite"]);
	expect(seen).not.toContain("minimumReleaseAgeExclude");
	expect(workspace()).toBe(WORKSPACE);
});

test("a JS update under the floor refused only for young versions lifts the floor", () => {
	audit(["vite"]);
	world.young = ["rollup@5.0.1"];
	world.floorFixes = true;
	const { code, out } = fixes();
	expect(code).toBe(0);
	expect(out).toContain("updated it with the 24h floor lifted; excluded rollup@5.0.1 until 24h old.");
});

test("commits an exact exclusion for each young version the fix locks", () => {
	audit(["vite"]);
	world.young = ["@esbuild/darwin-arm64@0.30.1", "rollup@5.0.1"];
	world.lockedYoung = ["vite@8.3.2"];
	const { code, out } = fixes();
	expect(code).toBe(0);
	// Refused with the floor in force, refused again with only vite
	// excluded, then accepted with the young versions excluded.
	expect(updates("update")).toHaveLength(3);
	expect(seen).toContain('  - "vite"\n  - "@esbuild/darwin-arm64@0.30.1"\n  - "rollup@5.0.1"\n');
	expect(workspace()).toBe(
		`${WORKSPACE}\n# Releases under 24h old taken to fix an advisory; scripts/age-excludes.ts\n` +
			"# drops each once it is 24h old.\nminimumReleaseAgeExclude:\n" +
			'  - "@esbuild/darwin-arm64@0.30.1"\n  - "rollup@5.0.1"\n  - "vite@8.3.2"\n',
	);
	expect(out).toContain("excluded @esbuild/darwin-arm64@0.30.1, rollup@5.0.1, vite@8.3.2 until 24h old");
});

test("keeps the exclusions already committed", () => {
	audit(["vite"]);
	world.lockedYoung = ["vite@8.3.2", "svelte@5.9.0"];
	files.set("pnpm-workspace.yaml", `${WORKSPACE}\nminimumReleaseAgeExclude:\n  - "svelte@5.9.0"\n`);
	expect(fixes().code).toBe(0);
	expect(workspace()).toContain('minimumReleaseAgeExclude:\n  - "svelte@5.9.0"\n  - "vite@8.3.2"\n');
});

test("an update failing for another reason refuses, restoring the workspace", () => {
	audit(["vite"]);
	world.failUpdate = true;
	const { code, out } = fixes();
	expect(code).toBe(1);
	expect(out).toContain("pre-commit: pnpm -r update --ignore-scripts --latest vite failed:\nERR_PNPM_BROKEN");
	expect(workspace()).toBe(WORKSPACE);
});

test("a failure after the floor is lifted refuses, restoring the workspace", () => {
	audit(["vite"]);
	world.young = ["rollup@5.0.1"];
	world.failInstall = true;
	const { code, out } = fixes();
	expect(code).toBe(1);
	expect(out).toContain("ERR_PNPM_BROKEN_INSTALL");
	expect(seen).toContain("minimumReleaseAgeExclude");
	expect(workspace()).toBe(WORKSPACE);
});

test.each([
	["ERR_PNPM_AUDIT_BAD_RESPONSE", "pnpm audit produced no JSON report (exit 1):\nERR_PNPM_AUDIT_BAD_RESPONSE"],
	["{}", "pnpm audit produced no advisories list (exit 1)."],
	['{"advisories": {"1": {}}}', "pnpm audit named no package for an advisory."],
])("an unreadable pnpm audit refuses (%s)", (report, why) => {
	world.audit = report;
	const { code, out } = fixes();
	expect(code).toBe(1);
	expect(out).toContain(`pre-commit: ${why}`);
});

test("a Hex fix 24h old is taken without lifting the cooldown", () => {
	hexAudit("Advisories:\n  plug 1.18.0 - GHSA-aaaa: Header injection\n");
	world.floorFixes = true;
	const { code, out } = fixes();
	expect(code).toBe(0);
	expect(out).toContain("plug had advisories; updated to fixes 24h old.");
	expect(updates("deps.update")).toEqual(["mix deps.update plug"]);
});

test("Hex packages with advisories are updated with the cooldown off", () => {
	hexAudit(
		"Advisories:\n" +
			"  plug 1.18.0 - GHSA-aaaa: Header injection\n" +
			"  bandit 1.8.0 - GHSA-bbbb: Request smuggling\n" +
			"  plug 1.18.0 - GHSA-cccc: Cookie parsing\n" +
			"Retired packages:\n" +
			"  jason 1.4.0 - Deprecated\n",
	);
	const { code, out } = fixes();
	expect(code).toBe(0);
	expect(out).toContain("plug, bandit had advisories; updated with the 24h floor lifted.");
	expect(updates("deps.update")).toEqual(["mix deps.update plug bandit", "mix deps.update plug bandit HEX_COOLDOWN=0d"]);
});

test("the Hex cooldown is lifted only for packages a fix 24h old leaves", () => {
	hexAudit("Advisories:\n  plug 1.18.0 - GHSA-aaaa: Header injection\n  bandit 1.8.0 - GHSA-bbbb: Request smuggling\n");
	world.hexAfterFloor = "Advisories:\n  bandit 1.8.0 - GHSA-bbbb: Request smuggling\n";
	const { code, out } = fixes();
	expect(code).toBe(0);
	expect(updates("deps.update")).toEqual(["mix deps.update plug bandit", "mix deps.update bandit HEX_COOLDOWN=0d"]);
	expect(out).toContain("plug had advisories; updated to fixes 24h old.");
	expect(out).toContain("bandit had advisories; updated with the 24h floor lifted.");
});

test("only retired Hex packages update nothing", () => {
	hexAudit("Retired packages:\n  jason 1.4.0 - Deprecated\n");
	expect(fixes().code).toBe(0);
	expect(updates("deps.update")).toEqual([]);
});

test("an unfetched Hex record refuses", () => {
	world.hexErr = "Failed to fetch record for plug\n";
	const { code, out } = fixes();
	expect(code).toBe(1);
	expect(out).toContain("Hex could not fetch every package's record:\nFailed to fetch record for plug");
});

test("a failing hex.audit with no report refuses", () => {
	hexAudit("** (Mix) boom\n");
	const { code, out } = fixes();
	expect(code).toBe(1);
	expect(out).toContain("mix hex.audit failed (exit 1):\n** (Mix) boom");
});

test("Hex advisories naming no package refuse", () => {
	hexAudit("Advisories:\n  something unexpected\n");
	const { code, out } = fixes();
	expect(code).toBe(1);
	expect(out).toContain("mix hex.audit listed advisories it named no package for");
});

test("a failed Hex update refuses", () => {
	hexAudit("Advisories:\n  plug 1.18.0 - GHSA-aaaa: Header injection\n");
	world.failHexUpdate = true;
	const { code, out } = fixes();
	expect(code).toBe(1);
	expect(out).toContain("pre-commit: mix deps.update plug failed:\nERR_DEPS\n");
});

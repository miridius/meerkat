import { describe, expect, test } from "bun:test";
import { published, type Ran, readExcludes, stale, untilAccepted, withExcludes, youngIn } from "./age-excludes";

const WORKSPACE = "packages:\n  - assets\nminimumReleaseAge: 1440\n";
const BLOCK =
	"\n# Releases under 24h old taken to fix an advisory; scripts/age-excludes.ts\n" +
	"# drops each once it is 24h old.\nminimumReleaseAgeExclude:\n";
const NOW = Date.parse("2026-11-12T12:00:00Z");
const OLD = "2020-01-01T00:00:00.000Z";
const YOUNG = "2026-11-12T10:00:00.000Z";

const excluding = (entries: string[]) => WORKSPACE + BLOCK + entries.map((e) => `  - "${e}"\n`).join("");

// pnpm view's publish times for each package, as the registry lists them.
const registry: Record<string, Record<string, string>> = {
	vite: { "8.3.2": YOUNG, "8.3.1": OLD },
	"@esbuild/darwin-arm64": { "0.30.1": OLD },
};
const view = (cmd: string[]): Ran => {
	const [pnpm, verb, name, ...rest] = cmd;
	expect([pnpm, verb, ...rest]).toEqual(["pnpm", "view", "time", "--json"]);
	return registry[name]
		? { code: 0, out: JSON.stringify(registry[name]), err: "" }
		: { code: 1, out: "", err: `404 ${name}\n` };
};

describe("stale", () => {
	test("picks the entries 24h old and leaves the young ones", () => {
		const entries = readExcludes(excluding(["@esbuild/darwin-arm64@0.30.1", "vite@8.3.2", "vite@8.3.1"]));
		expect(stale(entries, NOW, view)).toEqual(["@esbuild/darwin-arm64@0.30.1", "vite@8.3.1"]);
	});

	test("finds none with no list", () => {
		expect(stale(readExcludes(WORKSPACE), NOW, view)).toEqual([]);
	});
});

describe("withExcludes", () => {
	test("keeps the entries left", () => {
		expect(withExcludes(excluding(["@esbuild/darwin-arm64@0.30.1", "vite@8.3.2"]), ["vite@8.3.2"])).toBe(
			excluding(["vite@8.3.2"]),
		);
	});

	test("drops the list with its last entry", () => {
		expect(withExcludes(excluding(["vite@8.3.1"]), [])).toBe(WORKSPACE);
	});

	test("keeps the keys around a list that is not last", () => {
		const text = `${excluding(["vite@8.3.1", "vite@8.3.2"])}allowBuilds: {}\n`;
		expect(withExcludes(text, ["vite@8.3.2"])).toBe(
			`${WORKSPACE}\nallowBuilds: {}\n${BLOCK}  - "vite@8.3.2"\n`,
		);
	});

	test("writes each entry once", () => {
		expect(withExcludes(WORKSPACE, ["a@1.0.0", "a@1.0.0"])).toBe(excluding(["a@1.0.0"]));
	});
});

describe("published", () => {
	test("reads the version's publish time", () => {
		expect(published("@esbuild/darwin-arm64@0.30.1", view)).toEqual(new Date(OLD));
	});

	test.each([
		["vite@9.0.0", view, "the registry lists no publish time for 9.0.0"],
		["proxied@1.0.0", () => ({ code: 0, out: "<html>", err: "" }), "pnpm view printed no JSON"],
		["missing@1.0.0", view, "pnpm view exited 1:\n404 missing"],
	])("fails closed on an unreadable time (%s)", (entry, read, why) => {
		expect(() => published(entry, read)).toThrow(`could not read when the registry published ${entry}: ${why}`);
	});

	test.each(["vite", "@types/*"])("refuses %s, not an exact name@version", (entry) => {
		expect(() => published(entry, view)).toThrow(`${entry} is not an exact name@version entry`);
	});
});

test("youngIn reads each version pnpm refuses, through colour and wrapping", () => {
	const out =
		"\x1b[31m      \x1b[0m  rollup@5.0.1 was published at 2026-10-\n" +
		"\x1b[31m      \x1b[0m15T13:13:29.674Z, within the minimumReleaseAge cutoff\n" +
		"\x1b[31m      \x1b[0m  @esbuild/darwin-arm64@0.30.1 was\npublished at 2026-10-15\n";
	expect(youngIn(out)).toEqual(["rollup@5.0.1", "@esbuild/darwin-arm64@0.30.1"]);
});

// pnpm refusing, as pnpm 12 does, each of YOUNG that the workspace it was
// last given does not exclude, and then ending with FAILURE, if any.
function refusing(young: string[], failure?: string) {
	const written: string[] = [];
	const runs: string[][] = [];
	const sys = {
		write: (path: string, body: string) => {
			expect(path).toBe("pnpm-workspace.yaml");
			written.push(body);
		},
		run: (cmd: string[]): Ran => {
			runs.push(cmd);
			const refused = young.filter((v) => !(written.at(-1) as string).includes(`"${v}"`));
			if (refused.length === 0) return { code: failure ? 1 : 0, out: failure ?? "", err: "" };
			const lines = refused.map(
				(v) =>
					`\x1b[31m      \x1b[0m  ${v} was published at 2026-10-\n` +
					"\x1b[31m      \x1b[0m15T13:13:29.674Z, within the minimumReleaseAge cutoff\n",
			);
			return { code: 1, out: "", err: lines.join("") };
		},
	};
	return { sys, written, runs };
}

describe("untilAccepted", () => {
	test("excludes each version refused until the command is accepted", () => {
		const { sys, written, runs } = refusing(["rollup@5.0.1", "vite@8.3.2"]);
		expect(untilAccepted(["pnpm", "install"], WORKSPACE, ["svelte@5.9.0"], sys)).toEqual([
			"rollup@5.0.1",
			"vite@8.3.2",
		]);
		expect(runs).toEqual([
			["pnpm", "install"],
			["pnpm", "install"],
		]);
		expect(written.at(-1)).toBe(excluding(["svelte@5.9.0", "rollup@5.0.1", "vite@8.3.2"]));
	});

	test("adds nothing when the command is accepted at once", () => {
		const { sys, written } = refusing([]);
		expect(untilAccepted(["pnpm", "install"], WORKSPACE, [], sys)).toEqual([]);
		expect(written).toEqual([WORKSPACE]);
	});

	test("refuses a failure that is not a young version", () => {
		const { sys } = refusing(["rollup@5.0.1"], "ERR_PNPM_BROKEN");
		expect(() => untilAccepted(["pnpm", "install"], WORKSPACE, [], sys)).toThrow(
			"pnpm install failed:\nERR_PNPM_BROKEN",
		);
	});

	test("gives up after 20 rounds", () => {
		const young = Array.from({ length: 25 }, (_, i) => `p${i}@1.0.0`);
		let round = 0;
		// Refuses one more each round.
		const sys = { write: () => {}, run: (): Ran => ({ code: 1, out: `${young[round++]} was published at`, err: "" }) };
		expect(() => untilAccepted(["pnpm", "install"], WORKSPACE, [], sys)).toThrow(
			`pnpm install kept refusing young versions: ${young.slice(0, 20).join(", ")}`,
		);
	});
});

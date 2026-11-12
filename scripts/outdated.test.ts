import { describe, expect, test } from "bun:test";
import { status } from "./deps-common.ts";
import { entry, Fake, HEX_HEADER, OLD, releases, YOUNG } from "./deps-fake.ts";
import { gitDepNames, hexUpstream, lockPin, matureStable, outdated } from "./outdated.ts";

const HEX_LOCK = `%{
  "mdex": {:hex, :mdex, "0.14.1", "abc", [:mix], [], "hexpm", "def"},
}
`;

const GIT_LOCK = `%{
  "mdex": {:hex, :mdex, "0.14.1", "abc", [:mix], [], "hexpm", "def"},
  "muex": {:git, "https://github.com/someone/muex.git", "a628d48", [ref: "a628d48"]},
  "plug_x": {:git, "https://github.com/someone/plug_x.git", "b1c2d3e", [ref: "b1c2d3e"]},
}
`;

const REFUSED =
	" ERR_PNPM_NO_MATURE_MATCHING_VERSION  Version 2.1.17 (released 24 hours ago) of lefthook-windows-x64 does not meet the minimumReleaseAge constraint\n";

function gate() {
	return new Fake({ "mix.lock": HEX_LOCK }).hexApi("plug", releases([["2.1.1", OLD], ["2.1.0", OLD]]));
}

const run = (fake: Fake) => status(outdated, fake.sys);

// The Funding link sorts first, so the gate must prefer the GitHub key.
function gitRelease(list: [string, string][], repo: string) {
	return releases(list, {
		meta: { links: { Funding: "https://github.com/sponsors/upstream", GitHub: `https://github.com/${repo}` } },
	});
}

// compare FAKE REPO RANGE STATUS: GitHub's compare report for RANGE in
// REPO, with its HTTP code appended as curl's -w writes it.
function compare(fake: Fake, repo: string, range: string, body: string | null, code = 200) {
	return fake.on(new RegExp(`^curl -sSL [\\s\\S]* https://api\\.github\\.com/repos/${repo}/compare/${range.replace(/[.]/g, "\\.")}$`), {
		stdout: `${body ?? ""}\n${code}`,
	});
}

const statusOf = (status: string) => JSON.stringify({ status });

function behind(fake: Fake) {
	fake.pnpmReport(JSON.stringify({ shiki: { current: "3.23.0", latest: "4.4.3" } }));
	fake.hexReport(`${HEX_HEADER}plug  1.20.3  2.1.0  Update not possible\n`);
}

test("a package behind latest without an exemption blocks the push", async () => {
	const fake = gate().pnpmReport(JSON.stringify({ vite: { current: "8.2.0", latest: "8.3.1" } }));
	fake.hexReport(`${HEX_HEADER}jason  dev,test  1.4.3  1.4.5  Update possible
plug  1.20.3  2.1.0  Update not possible
bandit  1.12.4  1.12.5  Update possible (cooldown)
`);

	expect(await run(fake)).toBe(1);
	expect(fake.text).toContain("BLOCKED: vite is outdated (latest: 8.3.1)");
	expect(fake.text).toContain("BLOCKED: jason is outdated (latest: 1.4.5)");
	expect(fake.text).toContain("BLOCKED: plug is outdated (latest: 2.1.0)");
	expect(fake.text).not.toContain("bandit is outdated");
	// The installability check ran on a scratch copy it removed.
	expect(fake.calls.find((c) => c.cmd.startsWith("pnpm -r update"))).toMatchObject({
		cmd: "pnpm -r update --latest --lockfile-only --ignore-scripts vite",
		cwd: "/scratch",
	});
	expect(fake.removed).toEqual(["/scratch"]);
});

test("current dependencies pass the gate", async () => {
	const fake = gate().on("bun scripts/toolchain.ts check", { stdout: "toolchain checked\n" });

	expect(await run(fake)).toBe(0);
	expect(fake.text).toContain("=== toolchain ===\ntoolchain checked");
	expect(fake.text).toEndWith("\nall dependencies current.");
});

test("a missing tool or unreachable registry blocks the push before any check", async () => {
	const fake = gate();
	fake.tools.delete("curl");
	expect(await run(fake)).toBe(1);
	expect(fake.text).toContain("required tool 'curl' missing — cannot check dependencies.");

	for (const registry of ["https://registry.npmjs.org", "https://hex.pm"]) {
		const fake = gate().on(`curl -sf --max-time 5 ${registry}`, { code: 7 });
		expect(await run(fake)).toBe(1);
		expect(fake.text).toContain(`${registry} unreachable — cannot verify dependencies are current.`);
		expect(fake.ran).not.toContain("mix deps.get --check-locked");
	}
});

describe("the toolchain and minimumReleaseAgeExclude checks", () => {
	for (const script of ["toolchain.ts", "age-excludes.ts"]) {
		test(`${script} finding a pin or entry off target blocks the push`, async () => {
			const fake = gate().on(`bun scripts/${script} check`, { stdout: "checked\n", code: 1 });

			expect(await run(fake)).toBe(1);
			expect(fake.text).toContain("checked");
			expect(fake.text).toContain("dependencies are behind latest");
		});

		test(`${script} unable to check blocks the push at once`, async () => {
			const fake = gate().exempt({ jason: entry("1.4.5") });
			fake.on(`bun scripts/${script} check`, { code: 2 });

			expect(await run(fake)).toBe(1);
			expect(fake.text).not.toContain("stale exemption");
		});
	}
});

test("an unreadable report blocks the push", async () => {
	for (const registry of [true, false]) {
		for (const report of ["", "[]", '"oops"', "null", '{"vite": {"current": "8.2.0"}}']) {
			const fake = gate().pnpmReport(registry ? "{}" : report, registry ? report : "{}");
			fake.on(/^pnpm -r outdated/, (call) => ({
				stdout: call.cmd.endsWith("=0") === registry ? report : "{}",
				stderr: " WARN  deprecated subdependency\n",
				code: 1,
			}));
			expect(await run(fake)).toBe(1);
			expect(fake.text).toContain("cannot check JS deps");
			expect(fake.text).toContain(" WARN  deprecated subdependency");
			expect(fake.text.includes("--config.minimum-release-age=0 produced")).toBe(registry);
		}
	}

	// pnpm exits 1 on finding outdated packages, and above 1 on breaking.
	const fake = gate().on(/^pnpm -r outdated/, { stdout: "{}", code: 2 });
	expect(await run(fake)).toBe(1);
	expect(fake.text).toContain("produced no JSON report (exit 2)");

	for (const [report, code] of [
		["** (Mix) boom\n", 1],
		[`${HEX_HEADER}** (Mix) Could not fetch registry\n`, 1],
		[`${HEX_HEADER}plug  1.20.3  2.1.1  Update retired (cooldown)\n`, 1],
		[`${HEX_HEADER}plug  1.20.3  2.1.1  Update not possible (cooldown)\n`, 1],
		[`${HEX_HEADER}mdex  0.14.1  0.14.1  Up-to-date\n`, 2],
	] as const) {
		const fake = gate().hexReport(report, code);
		expect(await run(fake)).toBe(1);
		expect(fake.text).toContain(`mix hex.outdated produced no readable dependency table (exit ${code})`);
		expect(fake.text).toContain(report.trimEnd());
	}
});

// Like real deps/ and node_modules/ after a rebase changes the lockfiles,
// the reports read deps/ and node_modules/, so the syncs come first, Hex
// before JS, since assets/package.json takes packages from deps/.
test("the syncs run once each, Hex first, before the reports, without the index Git exports", async () => {
	const fake = gate();

	expect(await run(fake)).toBe(0);
	const syncs = fake.calls.filter((c) => /deps\.get|pnpm install/.test(c.cmd));
	expect(syncs).toEqual([
		{ cmd: "mix deps.get --check-locked", env: { GIT_DIR: undefined, GIT_INDEX_FILE: undefined } },
		{
			cmd: "pnpm install --frozen-lockfile --ignore-scripts --prefer-offline",
			env: { GIT_DIR: undefined, GIT_INDEX_FILE: undefined },
		},
	]);
	expect(fake.ran.indexOf("pnpm install --frozen-lockfile --ignore-scripts --prefer-offline")).toBeLessThan(
		fake.ran.findIndex((c) => c.startsWith("pnpm -r outdated")),
	);
});

test("a sync that would change a lockfile blocks the push", async () => {
	const get = gate().on("mix deps.get --check-locked", { stdout: "** (Mix) lock would change\n", code: 1 });
	expect(await run(get)).toBe(1);
	expect(get.text).toContain("** (Mix) lock would change\ntest: mix deps.get --check-locked failed — cannot check Hex deps");
	expect(get.ran).not.toContain("pnpm install --frozen-lockfile --ignore-scripts --prefer-offline");

	const install = gate().on(/^pnpm install/, { stderr: "ERR_PNPM_OUTDATED_LOCKFILE\n", code: 1 });
	expect(await run(install)).toBe(1);
	expect(install.text).toContain("ERR_PNPM_OUTDATED_LOCKFILE");
	expect(install.text).toContain("pnpm install --frozen-lockfile failed — cannot check JS deps");
});

test("an exemption covering the latest release passes the gate", async () => {
	const fake = gate().exempt({ shiki: entry("4.4.3"), plug: entry("2.1.0") });
	behind(fake);

	expect(await run(fake)).toBe(0);
	expect(fake.text).toContain("exempt: shiki@4.4.3 (upstream needs shiki 3)");
	expect(fake.text).toContain("exempt: plug@2.1.0");
});

test("an exemption for an older release fails once a newer one is out", async () => {
	const fake = gate().exempt({ shiki: entry("4.4.2"), plug: entry("2.1.0") });
	behind(fake);

	expect(await run(fake)).toBe(1);
	expect(fake.text).toContain("stale exemption: shiki covers 4.4.2, but latest is 4.4.3");
	expect(fake.text).toContain("BLOCKED: shiki is outdated (latest: 4.4.3)");
});

// pnpm outdated reports the newest release past minimumReleaseAge as
// latest, so a release under 24h shows only once the floor is off.
describe("a JS release under 24h that pnpm outdated does not report", () => {
	const young = () =>
		gate().pnpmReport(
			JSON.stringify({ shiki: { current: "3.23.0", latest: "4.4.2" } }),
			JSON.stringify({ shiki: { current: "3.23.0", latest: "4.4.3" } }),
		);

	test("leaves the release pnpm reports required", async () => {
		const fake = young();
		expect(await run(fake)).toBe(1);
		expect(fake.text).toContain("BLOCKED: shiki is outdated (latest: 4.4.2)");
	});

	test("makes an exemption for the release pnpm reports stale", async () => {
		const fake = young().exempt({ shiki: entry("4.4.2") });
		expect(await run(fake)).toBe(1);
		expect(fake.text).toContain("stale exemption: shiki covers 4.4.2, but latest is 4.4.3");
	});

	test("is covered by an exemption naming it", async () => {
		const fake = young().exempt({ shiki: entry("4.4.3") });
		expect(await run(fake)).toBe(0);
		expect(fake.text).toContain("exempt: shiki@4.4.3");
	});
});

// pnpm outdated leaves out a package installed at the newest release
// past minimumReleaseAge, though a younger release makes it behind.
describe("a JS release under 24h when pnpm outdated leaves the package out", () => {
	const young = () => gate().pnpmReport("{}", JSON.stringify({ shiki: { current: "4.4.2", latest: "4.4.3" } }));

	test("passes the gate without an exemption", async () => {
		const fake = young();
		expect(await run(fake)).toBe(0);
		expect(fake.text).toContain("all dependencies current.");
	});

	test("is covered by an exemption naming it", async () => {
		const fake = young().exempt({ shiki: entry("4.4.3") });
		expect(await run(fake)).toBe(0);
		expect(fake.text).toContain("exempt: shiki@4.4.3");
	});

	test("makes an exemption for an older release stale", async () => {
		const fake = young().exempt({ shiki: entry("4.4.1") });
		expect(await run(fake)).toBe(1);
		expect(fake.text).toContain("stale exemption: shiki covers 4.4.1, but latest is 4.4.3");
		expect(fake.text).not.toContain("BLOCKED");
		expect(fake.text).not.toContain("not behind latest");
	});
});

describe("a JS release pnpm outdated reports but pnpm refuses to install", () => {
	const refused = () =>
		gate()
			.pnpmReport(JSON.stringify({ lefthook: { current: "2.1.16", latest: "2.1.17" } }))
			.on(/^pnpm -r update --latest --lockfile-only --ignore-scripts lefthook$/, {
				stdout: `Progress: resolved 1\n${REFUSED}`,
				code: 1,
			});

	test("passes the gate when a package version it requires is under 24h", async () => {
		const fake = refused();
		expect(await run(fake)).toBe(0);
		expect(fake.text).toContain("ERR_PNPM_NO_MATURE_MATCHING_VERSION  Version 2.1.17");
		expect(fake.text).not.toContain("Progress: resolved 1");
		expect(fake.text).toContain("too young: lefthook@2.1.17 requires a package version under the 24h floor");
		expect(fake.removed).toEqual(["/scratch"]);
	});

	test("blocks the push when it cannot copy the workspace", async () => {
		const fake = refused();
		fake.scratch = null;
		expect(await run(fake)).toBe(1);
		expect(fake.text).toContain("could not copy the workspace to a scratch dir — cannot check lefthook");
	});

	test("blocks the push when pnpm fails for another reason", async () => {
		const fake = refused().on(/^pnpm -r update/, { stderr: " ERR_PNPM_META_FETCH_FAIL  GET failed\n", code: 1 });
		expect(await run(fake)).toBe(1);
		expect(fake.text).toContain("ERR_PNPM_META_FETCH_FAIL");
		expect(fake.text).toContain("pnpm could not resolve lefthook's latest release (exit 1)");
		expect(fake.removed).toEqual(["/scratch"]);
	});
});

test("each exempted JS package passes, and an unexempted one blocks", async () => {
	const report = JSON.stringify({
		shiki: { current: "3.23.0", latest: "4.4.3" },
		vite: { current: "8.2.0", latest: "8.3.2" },
		lefthook: { current: "2.1.0", latest: "2.1.16" },
	});
	const fake = gate().exempt({ shiki: entry("4.4.3"), vite: entry("8.3.2") }).pnpmReport(report);

	expect(await run(fake)).toBe(1);
	expect(fake.text).toContain("exempt: shiki@4.4.3");
	expect(fake.text).toContain("exempt: vite@8.3.2");
	expect(fake.text).not.toContain("BLOCKED: shiki");
	expect(fake.text).not.toContain("BLOCKED: vite");
	expect(fake.text).toContain("BLOCKED: lefthook is outdated (latest: 2.1.16)");
});

describe("a Hex release in cooldown", () => {
	const cooling = () => gate().hexReport(`${HEX_HEADER}plug  1.20.3  2.1.1  Update possible (cooldown)\n`);

	test("passes the gate without an exemption", async () => {
		const fake = cooling();
		expect(await run(fake)).toBe(0);
		expect(fake.text).toContain("too young: plug@2.1.1 is under the 24h Hex cooldown");
	});

	test("makes an exemption for an older release stale", async () => {
		const fake = cooling().exempt({ plug: entry("2.1.0") });
		expect(await run(fake)).toBe(1);
		expect(fake.text).toContain("stale exemption: plug covers 2.1.0, but latest is 2.1.1");
		expect(fake.text).not.toContain("not behind latest");
	});

	test("is covered by an exemption naming it", async () => {
		const fake = cooling().exempt({ plug: entry("2.1.1") });
		expect(await run(fake)).toBe(0);
		expect(fake.text).toContain("exempt: plug@2.1.1");
	});
});

// Hex marks the cooldown only on a release the requirements admit.
describe("a Hex release the requirements exclude", () => {
	const excluded = () => gate().hexReport(`${HEX_HEADER}plug  1.20.3  2.1.1  Update not possible\n`);

	test("passes the gate while hex.pm published it under 24h ago", async () => {
		const fake = excluded().hexApi("plug", releases([["2.1.1", YOUNG], ["2.1.0", OLD]]));
		expect(await run(fake)).toBe(0);
		expect(fake.text).toContain("too young: plug@2.1.1 is under the 24h Hex cooldown");
	});

	test("blocks the push once it is 24h old", async () => {
		const fake = excluded();
		expect(await run(fake)).toBe(1);
		expect(fake.text).toContain("BLOCKED: plug is outdated (latest: 2.1.1)");
	});

	test("fails closed when hex.pm's record of it is unreadable", async () => {
		for (const [body, code, why] of [
			["", 0, "hex.pm sent no JSON"],
			["not json", 0, "hex.pm sent no JSON"],
			["{}", 0, "hex.pm's record lists no publish time for 2.1.1"],
			[releases([["2.1.0", OLD]]), 0, "hex.pm's record lists no publish time for 2.1.1"],
			["", 22, "curl exited 22"],
		] as const) {
			const fake = excluded().hexApi("plug", body, code);
			expect(await run(fake)).toBe(1);
			expect(fake.text).toContain(`test: could not read when hex.pm published plug 2.1.1 — cannot check Hex deps: ${why}`);
		}
	});
});

test("an exemption for a package that is not behind fails the gate", async () => {
	const fake = gate()
		.exempt({ shiki: entry("4.4.3"), jason: entry("1.4.5") })
		.pnpmReport(JSON.stringify({ shiki: { current: "3.23.0", latest: "4.4.3" } }));

	expect(await run(fake)).toBe(1);
	expect(fake.text).toContain("stale exemption: jason is not behind latest; remove its entry");
});

test("a missing or malformed exemption table fails the gate", async () => {
	for (const table of [
		{ shiki: "held back" },
		{ shiki: entry("") },
		{ shiki: entry("4.4.3", "") },
		{ shiki: { reason: "x" } },
		"[]",
		"",
		"null",
	]) {
		const fake = gate().exempt(table);
		expect(await run(fake)).toBe(1);
		expect(fake.text).toContain('each entry needs a "version" and a "reason"');
	}
	const fake = gate();
	delete fake.files["scripts/dep-exemptions.json"];
	expect(await run(fake)).toBe(1);
	expect(fake.text).toContain("scripts/dep-exemptions.json is missing or malformed");
});

describe("a Hex package taken from git", () => {
	function pinned() {
		const fake = gate();
		fake.files["mix.lock"] = GIT_LOCK;
		fake.hexApi("muex", gitRelease([["0.11.2", OLD]], "upstream/muex.git"));
		fake.hexApi("plug_x", gitRelease([["1.0.0", OLD]], "upstream/plug_x"));
		compare(fake, "upstream/muex", "v0.11.2...someone:muex:a628d48", statusOf("ahead"));
		compare(fake, "upstream/plug_x", "v1.0.0...someone:plug_x:b1c2d3e", statusOf("identical"));
		// Any other range is a missing tag.
		fake.on(/^curl -sSL [\s\S]*\/compare\/(?!v)/, { stdout: "\n404" });
		return fake;
	}

	test("counts as the latest Hex release its pinned commit contains", async () => {
		const fake = pinned();
		expect(await run(fake)).toBe(0);
		expect(fake.text).toContain("current: muex is pinned to a628d48, which contains upstream/muex v0.11.2");
		expect(fake.text).toContain("current: plug_x is pinned to b1c2d3e, which contains upstream/plug_x v1.0.0");
	});

	test("makes an exemption for a pin containing the latest Hex release stale", async () => {
		const fake = pinned().exempt({ muex: entry("0.11.2") });
		expect(await run(fake)).toBe(1);
		expect(fake.text).toContain("stale exemption: muex is not behind latest; remove its entry");
	});

	test("fails when the pinned commit does not contain the latest Hex release", async () => {
		for (const verdict of ["diverged", "behind"]) {
			// An exemption naming the release does not cover a pin without it.
			const fake = pinned().exempt({ muex: entry("0.11.2") });
			// The v-tag verdict stands; the gate does not go on to try this one.
			compare(fake, "upstream/muex", "0.11.2...someone:muex:a628d48", statusOf("ahead"));
			compare(fake, "upstream/muex", "v0.11.2...someone:muex:a628d48", statusOf(verdict));

			expect(await run(fake)).toBe(1);
			expect(fake.text).toContain(
				"BLOCKED: muex is pinned to a628d48, which does not contain upstream/muex v0.11.2;\n  move the pin onto a commit that contains 0.11.2, or depend on the Hex release",
			);
			expect(fake.text).not.toContain("plug_x is pinned to b1c2d3e, which does not");
			expect(fake.text).not.toContain("exempt: muex");
			expect(fake.text).not.toContain("stale exemption");
		}
	});

	test("finds a release tag without a v prefix", async () => {
		const fake = pinned();
		compare(fake, "upstream/plug_x", "v1.0.0...someone:plug_x:b1c2d3e", null, 404);
		compare(fake, "upstream/plug_x", "1.0.0...someone:plug_x:b1c2d3e", statusOf("ahead"));
		expect(await run(fake)).toBe(0);
		expect(fake.text).toContain("current: plug_x is pinned to b1c2d3e, which contains upstream/plug_x 1.0.0");
	});

	test("fails closed when GitHub finds neither release tag", async () => {
		const fake = pinned().exempt({ muex: entry("0.11.2") });
		compare(fake, "upstream/muex", "v0.11.2...someone:muex:a628d48", null, 404);
		expect(await run(fake)).toBe(1);
		expect(fake.text).toContain(
			"BLOCKED: muex — GitHub finds neither tag v0.11.2 nor 0.11.2 in upstream/muex, or not pin a628d48",
		);
		expect(fake.text).not.toContain("stale exemption");
	});

	test("fails closed when GitHub's comparison is unreadable or unreachable", async () => {
		for (const body of ["", "{}", "not json", statusOf(null as unknown as string)]) {
			const fake = pinned();
			compare(fake, "upstream/muex", "v0.11.2...someone:muex:a628d48", body);
			expect(await run(fake)).toBe(1);
			expect(fake.text).toContain(
				"BLOCKED: muex — could not read GitHub's comparison of its pin with upstream/muex v0.11.2",
			);
		}

		const fake = pinned().on(/^curl -sSL [\s\S]*muex/, { stderr: "curl: (28) timed out\n", code: 28 });
		expect(await run(fake)).toBe(1);
		expect(fake.text).toContain("curl: (28) timed out");
		expect(fake.text).toContain("BLOCKED: muex — could not reach GitHub to compare its pin with upstream/muex v0.11.2");
	});

	test("fails closed on any other HTTP answer, naming a likely rate limit", async () => {
		for (const code of [403, 429, 500]) {
			const fake = pinned();
			// A later tag spelling would pass, but an error answer is not a missing tag.
			compare(fake, "upstream/muex", "0.11.2...someone:muex:a628d48", statusOf("ahead"));
			compare(fake, "upstream/muex", "v0.11.2...someone:muex:a628d48", "{}", code);
			expect(await run(fake)).toBe(1);
			expect(fake.text).toContain(
				`BLOCKED: muex — GitHub answered HTTP ${code} comparing its pin with upstream/muex v0.11.2`,
			);
			expect(fake.text.includes("may be rate-limiting")).toBe(code !== 500);
		}
	});

	test("sends GITHUB_TOKEN, or else gh's token, to GitHub on stdin", async () => {
		const configs = (fake: Fake) => fake.calls.filter((c) => c.cmd.includes("api.github.com")).map((c) => c.stdin);

		const gh = pinned().on("gh auth token", { stdout: "gh-t0k\n" });
		expect(await run(gh)).toBe(0);
		expect(configs(gh)).toEqual(['header = "Authorization: Bearer gh-t0k"\n', 'header = "Authorization: Bearer gh-t0k"\n']);

		const env = pinned().on("gh auth token", { stdout: "gh-t0k\n" });
		env.env.GITHUB_TOKEN = "env-t0k";
		expect(await run(env)).toBe(0);
		expect(configs(env)[0]).toBe('header = "Authorization: Bearer env-t0k"\n');
		expect(env.ran).not.toContain("gh auth token");

		const none = pinned().on("gh auth token", { code: 1 });
		expect(await run(none)).toBe(0);
		expect(configs(none)[0]).toBe("\n");
	});

	test("fails closed when Hex links no GitHub repo", async () => {
		const fake = pinned().hexApi("muex", releases([["0.11.2", OLD]]));
		expect(await run(fake)).toBe(1);
		expect(fake.text).toContain("BLOCKED: muex — Hex links no GitHub repo to find release 0.11.2 in");
	});

	test("fails closed when mix.lock pins it outside https://github.com", async () => {
		const fake = pinned();
		fake.files["mix.lock"] = GIT_LOCK.replaceAll("https://github.com/", "https://gitlab.com/");
		expect(await run(fake)).toBe(1);
		expect(fake.text).toContain("BLOCKED: muex — mix.lock pins it to no https://github.com commit");
	});

	test("fails closed when Hex reports no release", async () => {
		for (const [body, code] of [
			["", 0],
			["{}", 0],
			["not json", 0],
			[releases([["0.11.2", YOUNG], ["0.11.1-rc.0", OLD]]), 0],
			[releases([["0.11.2", OLD]]), 22],
		] as const) {
			const fake = pinned().exempt({ muex: entry("0.11.2") }).hexApi("muex", body, code);
			expect(await run(fake)).toBe(1);
			expect(fake.text).toContain("BLOCKED: muex — no stable Hex release at least 24h old found");
			expect(fake.text).not.toContain("stale exemption");
		}
	});

	test("fails closed when mix.lock is unreadable", async () => {
		const fake = pinned();
		delete fake.files["mix.lock"];
		expect(await run(fake)).toBe(1);
		expect(fake.text).toContain("could not read mix.lock — cannot check git deps.");
	});
});

describe("mix.lock and hex.pm readers", () => {
	test("gitDepNames finds each package taken from git", () => {
		expect(gitDepNames(GIT_LOCK)).toEqual(["muex", "plug_x"]);
		expect(gitDepNames(HEX_LOCK)).toEqual([]);
	});

	test("lockPin reads the GitHub repo and commit, without .git", () => {
		expect(lockPin(GIT_LOCK, "muex")).toEqual({ repo: "someone:muex", sha: "a628d48" });
		expect(lockPin(GIT_LOCK, "mdex")).toBeNull();
		expect(lockPin(GIT_LOCK.replace('"a628d48", [', '"xyz", ['), "muex")).toBeNull();
	});

	test("matureStable takes the newest stable release at least 24h old", () => {
		const record = (list: [string, string][]) => JSON.parse(releases(list));
		expect(matureStable(record([["0.12.0", YOUNG], ["0.12.0-rc.0", OLD], ["0.11.2", OLD]]), Date.parse(YOUNG) + 43_200_000)).toBe(
			"0.11.2",
		);
		// Exactly 24h old is mature.
		expect(matureStable(record([["1.0.0", "2026-05-31T12:00:00Z"]]), Date.parse("2026-06-01T12:00:00Z"))).toBe("1.0.0");
		expect(matureStable(record([["1.0.0", "2026-05-31T12:00:01Z"]]), Date.parse("2026-06-01T12:00:00Z"))).toBeNull();
		// A publish time it cannot read is no answer.
		expect(matureStable(record([["1.0.0", "2026-05-31"]]), Date.parse("2026-06-01T12:00:00Z"))).toBeNull();
		expect(matureStable({}, 0)).toBeNull();
	});

	test("hexUpstream prefers the GitHub link, then Source, then any other", () => {
		const links = (l: Record<string, unknown>) => ({ meta: { links: l } });
		expect(hexUpstream(links({ Funding: "https://github.com/sponsors/x", GitHub: "https://github.com/a/b.git" }))).toBe(
			"a/b",
		);
		expect(hexUpstream(links({ Docs: "https://github.com/c/d#readme", Source: "https://github.com/e/f" }))).toBe("e/f");
		expect(hexUpstream(links({ Docs: "https://github.com/c/d?tab=1" }))).toBe("c/d");
		expect(hexUpstream(links({ Docs: "https://gitlab.com/c/d" }))).toBeNull();
		expect(hexUpstream({})).toBeNull();
	});
});

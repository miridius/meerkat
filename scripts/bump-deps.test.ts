import { describe, expect, test } from "bun:test";
import { bumpDeps, isPathCommit } from "./bump-deps.ts";
import { status } from "./deps-common.ts";
import { entry, Fake, HEX_HEADER, OLD, releases, YOUNG } from "./deps-fake.ts";

const HEX_BEHIND = `${HEX_HEADER}bandit            1.11.0   1.12.5  Update not possible
jason             1.4.3    1.4.5   Update possible
plug              1.20.3   2.1.0   Update not possible
mdex              0.14.1   0.14.1  Up-to-date
`;

const PNPM_BEHIND = JSON.stringify({
	vite: { current: "8.2.0", latest: "8.3.1" },
	shiki: { current: "3.23.0", latest: "4.4.3" },
});

const REFUSED =
	" ERR_PNPM_NO_MATURE_MATCHING_VERSION  Version 2.1.17 (released 24 hours ago) of lefthook-windows-x64 does not meet the minimumReleaseAge constraint\n";

const DEP_FILES = ["mix.exs", "mix.lock", "package.json", "pnpm-lock.yaml", "assets/package.json"];

// A tree whose dependency files read "base", where git hashes a file to
// its content, and each update appends to the files it would change.
function tree() {
	const fake = new Fake(Object.fromEntries(DEP_FILES.map((f) => [f, "base\n"])));
	const append = (file: string, line: string) => {
		fake.files[file] = `${fake.files[file] ?? ""}${line}\n`;
	};
	fake.exempt({ shiki: entry("4.4.3") });
	fake.on(/^git hash-object -- /, ({ cmd }) => {
		const file = cmd.slice("git hash-object -- ".length);
		return file in fake.files ? { stdout: `${fake.files[file]}\n` } : { stderr: "fatal: no such file\n", code: 128 };
	});
	fake.on("git hash-object -w -- mix.exs", () => ({ stdout: "blob:mix.exs\n" }));
	fake.on("git cat-file blob blob:mix.exs", { stdout: "base\n" });
	fake.on(/^elixir scripts\/bump-hex-requirements\.exs /, ({ cmd }) => {
		append("mix.exs", `requirements ${cmd.split(" ").slice(2).join(" ")}`);
		return {};
	});
	fake.on(/^mix deps\.update /, ({ cmd }) => {
		append("mix.lock", `updated ${cmd.slice("mix deps.update ".length)}`);
		return {};
	});
	fake.on(/^pnpm -r update --latest --ignore-scripts /, ({ cmd }) => {
		const names = cmd.slice("pnpm -r update --latest --ignore-scripts ".length);
		for (const file of ["package.json", "assets/package.json", "pnpm-lock.yaml"]) append(file, `updated ${names}`);
		return {};
	});
	fake.hexApi("bandit", releases([["1.12.5", OLD]]));
	fake.hexApi("plug", releases([["2.1.0", OLD]]));
	fake.hexApi("jason", releases([["1.4.5", OLD]]));
	return fake;
}

const run = (fake: Fake) => status(bumpDeps, fake.sys);

const staged = (fake: Fake) => fake.ran.find((c) => c.startsWith("git add -- "))?.slice("git add -- ".length).split(" ");

const updates = (fake: Fake) => fake.ran.filter((c) => /^(elixir|mix deps\.update|pnpm -r update --latest --ignore)/.test(c));

test("a commit while dependencies are behind carries their bump", async () => {
	const fake = tree().hexReport(HEX_BEHIND).pnpmReport(PNPM_BEHIND);

	expect(await run(fake)).toBe(0);
	// The exempt shiki is left behind.
	expect(updates(fake)).toEqual([
		"elixir scripts/bump-hex-requirements.exs bandit 1.12.5 plug 2.1.0",
		"mix deps.update bandit jason plug",
		"pnpm -r update --latest --ignore-scripts vite",
	]);
	expect(fake.files["mix.lock"]).toBe("base\nupdated bandit jason plug\n");
	expect(staged(fake)).toEqual(DEP_FILES);
	expect(fake.ran).toContain(`git diff --stat -- ${DEP_FILES.join(" ")}`);
	expect(fake.text).toEndWith("test: staged the dependency bump into this commit.");
});

test("an exemption for an older release does not hold back a newer one", async () => {
	const fake = tree()
		.exempt({ shiki: entry("4.4.2") })
		.pnpmReport(PNPM_BEHIND)
		.on("pnpm view shiki dist-tags.latest", { stdout: "4.4.3\n" });

	expect(await run(fake)).toBe(0);
	expect(updates(fake)).toEqual(["pnpm -r update --latest --ignore-scripts vite shiki"]);
	// shiki's entry does not name pnpm's latest, so the registry's latest is read too.
	expect(fake.ran).toContain("pnpm view shiki dist-tags.latest");
});

test("a commit while everything is current changes no dependency file", async () => {
	const fake = tree();

	expect(await run(fake)).toBe(0);
	expect(updates(fake)).toEqual([]);
	expect(staged(fake)).toBeUndefined();
	expect(fake.text).not.toContain("staged the dependency bump");
});

test("only the dependency files the bump changed are staged", async () => {
	const fake = tree().pnpmReport(JSON.stringify({ vite: { current: "8.2.0", latest: "8.3.1" } }));
	// An unstaged edit the bump leaves alone stays unstaged.
	fake.files["mix.lock"] = "base\nwork in progress\n";
	// A file that does not exist is no change.
	expect(await run(fake)).toBe(0);
	expect(staged(fake)).toEqual(["package.json", "pnpm-lock.yaml", "assets/package.json"]);
});

test("the syncs run first, Hex then JS, without the index Git exports", async () => {
	const fake = tree();

	expect(await run(fake)).toBe(0);
	const reads = fake.calls.filter((c) => !c.cmd.startsWith("git"));
	expect(reads.slice(0, 3)).toEqual([
		{ cmd: "mix deps.get --check-locked", env: { GIT_DIR: undefined, GIT_INDEX_FILE: undefined } },
		{
			cmd: "pnpm install --frozen-lockfile --ignore-scripts --prefer-offline",
			env: { GIT_DIR: undefined, GIT_INDEX_FILE: undefined },
		},
		{ cmd: "mix hex.outdated" },
	]);
});

describe("refuses the commit, updating nothing,", () => {
	const refused = async (fake: Fake, message: string) => {
		expect(await run(fake)).toBe(1);
		expect(fake.text).toContain(message);
		expect(updates(fake)).toEqual([]);
		expect(staged(fake)).toBeUndefined();
	};

	test("on an unreadable Hex report", async () => {
		for (const report of ["** (Mix) boom\n", `${HEX_HEADER}** (Mix) Could not fetch registry\n`])
			await refused(tree().hexReport(report), "cannot check Hex deps");
	});

	test("on a sync that would change a lockfile", async () => {
		await refused(
			tree().on("mix deps.get --check-locked", { code: 1 }),
			"mix deps.get --check-locked failed — cannot check Hex deps",
		);
		await refused(
			tree().on(/^pnpm install /, { code: 1 }),
			"pnpm install --frozen-lockfile failed — cannot check JS deps",
		);
	});

	test("on an unreadable pnpm report", async () => {
		for (const report of ["", "[]", '"oops"', "null", '{"vite": {"current": "8.2.0"}}'])
			await refused(tree().pnpmReport(report), "cannot check JS deps");
	});

	test("on a malformed exemption table", async () => {
		for (const table of ['{"shiki": {"reason": "x"}}', "[]", ""])
			await refused(tree().exempt(table).pnpmReport(PNPM_BEHIND), 'each entry needs a "version" and a "reason"');
	});

	test("on a missing tool", async () => {
		const fake = tree();
		fake.tools.delete("elixir");
		await refused(fake, "required tool 'elixir' missing");
	});

	test("on an unreadable hex.pm record", async () => {
		await refused(tree().hexReport(HEX_BEHIND).hexApi("plug", ""), "could not read when hex.pm published plug 2.1.0");
	});

	test("on a registry latest it cannot read for an exempt package", async () => {
		const fake = tree()
			.exempt({ shiki: entry("4.4.1") })
			.pnpmReport(JSON.stringify({ shiki: { current: "3.23.0", latest: "4.4.2" } }))
			.on("pnpm view shiki dist-tags.latest", { stdout: "4.4.3\n4.4.4\n" });
		await refused(fake, "could not read shiki's latest release from the registry — cannot check its exemption.");
	});

	test("on a JS release pnpm cannot resolve for another reason", async () => {
		const fake = tree()
			.pnpmReport(PNPM_BEHIND)
			.on(/^pnpm -r update --latest --lockfile-only/, { stderr: " ERR_PNPM_META_FETCH_FAIL  GET failed\n", code: 1 });
		await refused(fake, "pnpm could not resolve vite's latest release (exit 1)");
	});
});

test("a requirement it cannot move refuses the commit", async () => {
	const fake = tree().hexReport(`${HEX_HEADER}plug  1.0.0  2.1.0  Update not possible\n`);
	fake.on(/^elixir /, { stderr: 'pre-commit: mix.exs plug "== 1.0.0" excludes 2.1.0; edit the requirement by hand.\n', code: 1 });

	expect(await run(fake)).toBe(1);
	expect(fake.text).toContain('mix.exs plug "== 1.0.0" excludes 2.1.0');
	expect(fake.ran.some((c) => c.startsWith("mix deps.update"))).toBe(false);
});

test("a failed update refuses the commit and restores mix.exs", async () => {
	const fake = tree().hexReport(HEX_BEHIND).on(/^mix deps\.update /, { code: 1 });

	expect(await run(fake)).toBe(1);
	expect(fake.text).toContain("test: mix deps.update bandit jason plug failed, so the commit was refused.");
	expect(fake.files["mix.exs"]).toBe("base\n");
	expect(staged(fake)).toBeUndefined();
});

test("an update within mix.exs's requirements saves no copy of it", async () => {
	const fake = tree()
		.hexReport(`${HEX_HEADER}jason  1.4.3  1.4.5  Update possible\n`)
		.on(/^mix deps\.update /, { code: 1 });

	expect(await run(fake)).toBe(1);
	expect(fake.ran.filter((c) => c.startsWith("git hash-object -w") || c.startsWith("git cat-file"))).toEqual([]);
	expect(fake.files["mix.exs"]).toBe("base\n");
});

test("a mix.exs it cannot save refuses the commit before any update, saying why", async () => {
	const fake = tree()
		.hexReport(HEX_BEHIND)
		.on("git hash-object -w -- mix.exs", { stderr: "fatal: unable to write object\n", code: 128 });

	expect(await run(fake)).toBe(1);
	expect(fake.text).toContain("fatal: unable to write object\ntest: could not save mix.exs before bumping its requirements.");
	expect(fake.ran.some((c) => c.startsWith("elixir ") || c.startsWith("mix deps.update"))).toBe(false);
});

test("a mix.exs it cannot restore is left as the bump wrote it, saying how to restore it", async () => {
	const fake = tree()
		.hexReport(HEX_BEHIND)
		.on(/^mix deps\.update /, { code: 1 })
		.on("git cat-file blob blob:mix.exs", { stderr: "fatal: Not a valid object name\n", code: 128 });

	expect(await run(fake)).toBe(1);
	expect(fake.text).toContain(
		"fatal: Not a valid object name\ntest: could not restore mix.exs; `git cat-file blob blob:mix.exs > mix.exs` restores it.",
	);
	expect(fake.files["mix.exs"]).toBe("base\nrequirements bandit 1.12.5 plug 2.1.0\n");
});

// pnpm outdated reports the newest release past minimumReleaseAge as
// latest, so a release under 24h shows only in the registry's latest.
describe("an entry while a JS release is under 24h", () => {
	const young = (version: string) =>
		tree()
			.exempt({ shiki: entry(version, "x") })
			.pnpmReport(JSON.stringify({ shiki: { current: "3.23.0", latest: "4.4.2" } }))
			.on("pnpm view shiki dist-tags.latest", { stdout: "4.4.3\n" });

	for (const [version, which] of [
		["4.4.2", "the release pnpm reports"],
		["4.4.3", "the young one"],
	])
		test(`naming ${which} leaves the package alone`, async () => {
			const fake = young(version);
			expect(await run(fake)).toBe(0);
			expect(updates(fake)).toEqual([]);
		});

	test("naming an older release does not hold it back", async () => {
		const fake = young("4.4.1");
		expect(await run(fake)).toBe(0);
		expect(updates(fake)).toEqual(["pnpm -r update --latest --ignore-scripts shiki"]);
	});
});

test("a JS release pnpm refuses for a younger version it requires is left behind", async () => {
	const fake = tree()
		.pnpmReport(
			JSON.stringify({ vite: { current: "8.2.0", latest: "8.3.1" }, lefthook: { current: "2.1.16", latest: "2.1.17" } }),
		)
		.on("pnpm -r update --latest --lockfile-only --ignore-scripts lefthook", { stdout: REFUSED, code: 1 });

	expect(await run(fake)).toBe(0);
	expect(fake.text).toContain("ERR_PNPM_NO_MATURE_MATCHING_VERSION  Version 2.1.17");
	expect(fake.text).toContain("lefthook@2.1.17 requires a package version under the 24h floor; not bumped yet");
	expect(updates(fake)).toEqual(["pnpm -r update --latest --ignore-scripts vite"]);
	// The installability checks ran on scratch copies, not the tree.
	expect(fake.calls.filter((c) => c.cmd.includes("--lockfile-only")).map((c) => c.cwd)).toEqual(["/scratch", "/scratch"]);
	expect(fake.removed).toEqual(["/scratch", "/scratch"]);
});

test("an exempt Hex release is left behind", async () => {
	const fake = tree()
		.exempt({ plug: entry("2.1.0", "x"), jason: entry("1.4.5", "x") })
		.hexReport(HEX_BEHIND);

	expect(await run(fake)).toBe(0);
	expect(updates(fake)).toEqual(["elixir scripts/bump-hex-requirements.exs bandit 1.12.5", "mix deps.update bandit"]);
});

test("Hex rows with an Only column or in cooldown parse by their Status", async () => {
	const fake = tree().hexReport(`${HEX_HEADER}credo  dev,test  1.7.18  1.7.19  Update possible
jason  1.4.3  1.4.5  Update possible (cooldown)
plug  test  1.20.3  2.1.0  Update not possible

Run \`mix hex.outdated APP\` to see requirements for a specific dependency.
`);

	expect(await run(fake)).toBe(0);
	expect(updates(fake)).toEqual(["elixir scripts/bump-hex-requirements.exs plug 2.1.0", "mix deps.update credo plug"]);
});

// Hex marks the cooldown only on a release the requirements admit.
test("a release the requirements exclude is left behind while under 24h old", async () => {
	const fake = tree().hexReport(HEX_BEHIND).hexApi("plug", releases([["2.1.0", YOUNG]]));

	expect(await run(fake)).toBe(0);
	expect(updates(fake)).toEqual([
		"elixir scripts/bump-hex-requirements.exs bandit 1.12.5",
		"mix deps.update bandit jason",
	]);
});

test("the exclusion prune, advisory fixes, toolchain bump and setup run after the dependency bump, and their changes are staged", async () => {
	const fake = tree().pnpmReport(PNPM_BEHIND);
	fake.on("bun scripts/age-excludes.ts prune", () => {
		fake.files["pnpm-workspace.yaml"] = "pruned\n";
		return {};
	});
	fake.on("bun scripts/toolchain.ts bump", () => {
		fake.files[".tool-versions"] = "bun 9.9.9\n";
		fake.files[".github/actions/toolchain/action.yml"] = "bumped\n";
		return {};
	});

	expect(await run(fake)).toBe(0);
	expect(fake.ran.filter((c) => /^(pnpm -r update --latest --ignore|bun )/.test(c))).toEqual([
		"pnpm -r update --latest --ignore-scripts vite",
		"bun scripts/age-excludes.ts prune",
		"bun scripts/advisory-fixes.ts",
		"bun scripts/toolchain.ts bump",
		"bun scripts/setup-toolchain.ts",
	]);
	expect(staged(fake)).toEqual([
		"package.json",
		"pnpm-lock.yaml",
		"assets/package.json",
		"pnpm-workspace.yaml",
		".tool-versions",
		".github/actions/toolchain/action.yml",
	]);
});

for (const script of ["age-excludes.ts prune", "advisory-fixes.ts", "toolchain.ts bump", "setup-toolchain.ts"])
	test(`a failing ${script} refuses the commit, staging nothing`, async () => {
		const fake = tree().pnpmReport(PNPM_BEHIND).on(`bun scripts/${script}`, { stdout: "failed\n", code: 3 });
		expect(await run(fake)).toBe(3);
		expect(staged(fake)).toBeUndefined();
	});

test("a path commit defers the bump", async () => {
	const fake = tree().hexReport(HEX_BEHIND);
	fake.env.GIT_INDEX_FILE = "/repo/.git/next-index-123.lock";

	expect(await run(fake)).toBe(0);
	expect(fake.text).toBe("test: path commit; dependency bump deferred to the next full commit.");
	expect(fake.calls).toEqual([]);
});

test("isPathCommit tells a path commit's index from the real one", () => {
	expect(isPathCommit(undefined)).toBe(false);
	expect(isPathCommit("")).toBe(false);
	expect(isPathCommit("/repo/.git/index")).toBe(false);
	// `git commit -a` exports the locked real index.
	expect(isPathCommit("/repo/.git/index.lock")).toBe(false);
	expect(isPathCommit("/repo/.git/worktrees/w/index.lock")).toBe(false);
	expect(isPathCommit("/repo/.git/next-index-123.lock")).toBe(true);
});

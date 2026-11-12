import { expect, test } from "bun:test";
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseExemptions, parseHexOutdated, parsePnpmOutdated, publishedAt, scratchWorkspace } from "./deps-common.ts";
import { HEX_HEADER, OLD, releases } from "./deps-fake.ts";

test("parseHexOutdated reads each row behind latest by its Status", () => {
	expect(
		parseHexOutdated(`Resolving Hex dependencies...
${HEX_HEADER}credo  dev,test  1.7.18  1.7.19  Update possible
jason  1.4.3  1.4.5  Update possible (cooldown)
plug  test  1.20.3  2.1.0  Update not possible
mdex  0.14.1  0.14.1  Up-to-date

Run \`mix hex.outdated APP\` to see requirements for a specific dependency.
bogus row
`),
	).toEqual([
		{ name: "credo", latest: "1.7.19", status: "possible" },
		{ name: "jason", latest: "1.4.5", status: "cooldown" },
		{ name: "plug", latest: "2.1.0", status: "not" },
	]);
	expect(parseHexOutdated(`${HEX_HEADER}`)).toEqual([]);
});

test("parseHexOutdated refuses a report without a table or with a status it does not know", () => {
	for (const report of [
		"** (Mix) boom",
		`${HEX_HEADER}** (Mix) Could not fetch registry`,
		`${HEX_HEADER}plug  1.20.3  2.1.1  Update retired (cooldown)`,
		`${HEX_HEADER}plug  1.20.3  2.1.1  Update not possible (cooldown)`,
		// Status is found from the fourth field on.
		`${HEX_HEADER}plug  Update  2.1.1`,
	])
		expect(parseHexOutdated(report)).toBeNull();
});

test("parsePnpmOutdated reads each package's latest, or refuses the report", () => {
	expect(parsePnpmOutdated('{"vite": {"current": "8.2.0", "latest": "8.3.1"}}')).toEqual([
		{ name: "vite", latest: "8.3.1" },
	]);
	expect(parsePnpmOutdated("{}")).toEqual([]);
	for (const report of ["", "[]", '"oops"', "null", '{"vite": {"current": "8.2.0"}}', '{"vite": null}'])
		expect(parsePnpmOutdated(report)).toBeNull();
});

test("parseExemptions needs a non-empty version and reason in each entry", () => {
	const table = { shiki: { version: "4.4.3", reason: "x" } };
	expect(parseExemptions(JSON.stringify(table))).toEqual(table);
	expect(parseExemptions("{}")).toEqual({});
	for (const text of [
		null,
		"",
		"[]",
		"null",
		'{"shiki": "held back"}',
		'{"shiki": []}',
		'{"shiki": {"version": "", "reason": "x"}}',
		'{"shiki": {"version": "4.4.3", "reason": ""}}',
		'{"shiki": {"version": 4, "reason": "x"}}',
	])
		expect(parseExemptions(text)).toBeNull();
});

test("publishedAt reads a release's publish time from hex.pm's record", () => {
	expect(publishedAt(releases([["2.1.0", OLD]]), "2.1.0")).toEqual(new Date(OLD));
	expect(publishedAt(releases([["2.1.0", OLD]]), "2.1.1")).toBe("hex.pm's record lists no publish time for 2.1.1");
	expect(publishedAt("{}", "2.1.1")).toBe("hex.pm's record lists no publish time for 2.1.1");
	expect(publishedAt("[]", "2.1.1")).toBe("hex.pm's record lists no publish time for 2.1.1");
	expect(publishedAt("", "2.1.1")).toStartWith("hex.pm sent no JSON (");
});

test("scratchWorkspace copies the workspace and its patches, linking deps/", () => {
	const root = mkdtempSync(join(tmpdir(), "meerkat-workspace-"));
	try {
		mkdirSync(join(root, "assets"));
		mkdirSync(join(root, "patches"));
		for (const file of ["package.json", "pnpm-workspace.yaml", "pnpm-lock.yaml", "assets/package.json"])
			writeFileSync(join(root, file), file);
		writeFileSync(join(root, "patches/pkg.patch"), "the patch\n");

		const errors: string[] = [];
		const copy = scratchWorkspace(root, (text) => errors.push(text));
		expect(copy).not.toBeNull();
		try {
			for (const file of ["package.json", "pnpm-workspace.yaml", "pnpm-lock.yaml", "assets/package.json"]) {
				expect(readFileSync(join(copy as string, file), "utf8")).toBe(file);
				// A write in the copy leaves the tree's file alone.
				writeFileSync(join(copy as string, file), "changed");
				expect(readFileSync(join(root, file), "utf8")).toBe(file);
			}
			expect(readFileSync(join(copy as string, "patches/pkg.patch"), "utf8")).toBe("the patch\n");
			expect(lstatSync(join(copy as string, "deps")).isSymbolicLink()).toBe(true);
			expect(readlinkSync(join(copy as string, "deps"))).toBe(join(root, "deps"));
		} finally {
			rmSync(copy as string, { recursive: true });
		}

		expect(errors).toEqual([]);

		// Without pnpm-workspace.yaml it makes none, saying why, and leaves
		// nothing behind.
		rmSync(join(root, "pnpm-workspace.yaml"));
		const before = new Set(readdirSync(tmpdir()));
		expect(scratchWorkspace(root, (text) => errors.push(text))).toBeNull();
		expect(errors).toEqual([expect.stringContaining("ENOENT")]);
		const left = readdirSync(tmpdir()).filter((name) => !before.has(name) && name.startsWith("meerkat-pnpm-"));
		expect(left).toEqual([]);
		expect(existsSync(root)).toBe(true);
	} finally {
		rmSync(root, { recursive: true });
	}
});

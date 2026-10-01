import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { attachShots, parseArgs, type Shot, withScreenshots } from "../../../scripts/pr-screenshots.ts";

const OUT = "/shots/meerkat-pr-7-screenshots";
const START = "<!-- meerkat-screenshots -->";
const END = "<!-- /meerkat-screenshots -->";

const base = (name: string, caption?: string): Shot => ({ name, code: "base", file: `base-${name}.png`, caption });
const head = (name: string, caption?: string): Shot => ({ name, code: "head", file: `head-${name}.png`, caption });
const count = (text: string, part: string) => text.split(part).length - 1;

describe("withScreenshots", () => {
	test("appends a block after a description that has none and keeps that description as it was", () => {
		const body = "## What\n\n- a change\n\n_Written by Opus 5.5_";
		const result = withScreenshots(body, OUT, [head("split")]);

		expect(result.startsWith(`${body}\n\n${START}`)).toBe(true);
		expect(result.endsWith(END)).toBe(true);
		expect(result).toContain(`![split](${OUT}/head-split.png)`);
	});

	test("makes a block alone of an empty description", () => {
		expect(withScreenshots("", OUT, [head("split")]).startsWith(START)).toBe(true);
	});

	test("labels and pairs before and after shots, and shows a caption above its image", () => {
		const shots = [base("a"), base("b"), head("a", "the first"), head("b")];
		const result = withScreenshots("body", OUT, shots);

		const order = ["before a", "after a", "before b", "after b"].map((alt) => result.indexOf(`![${alt}]`));
		expect(order.every((i) => i > 0)).toBe(true);
		expect(order).toEqual([...order].sort((x, y) => x - y));
		expect(result).toContain(`the first\n\n![after a](${OUT}/head-a.png)`);
	});

	test("replaces an earlier block, leaving the text around it exactly as it is", () => {
		const earlier = withScreenshots("intro", OUT, [head("old")]).replace("/head-old.png", "/uploaded-old.png");
		const edited = `${earlier.replace("intro", "intro, edited")}\n\nnotes added after the block\r\n`;
		const result = withScreenshots(edited, OUT, [base("new"), head("new")]);

		expect(result.startsWith("intro, edited\n\n")).toBe(true);
		expect(result.endsWith("\n\nnotes added after the block\r\n")).toBe(true);
		expect(count(result, START)).toBe(1);
		expect(count(result, END)).toBe(1);
		expect(result).not.toContain("old");
		expect(result).toContain(`![before new](${OUT}/base-new.png)`);
	});

	test("is stable: a second run over its own output changes nothing", () => {
		const once = withScreenshots("body", OUT, [base("a"), head("a")]);
		expect(withScreenshots(once, OUT, [base("a"), head("a")])).toBe(once);
	});

	test("appends rather than swallowing text when a marker was deleted from the description", () => {
		const body = `before\n\n${START}\n\nnote the user wrote\n\nafter`;
		const result = withScreenshots(body, OUT, [head("a")]);

		expect(result.startsWith(body)).toBe(true);
		expect(withScreenshots(result, OUT, [head("b")]).startsWith(body)).toBe(true);
		expect(count(withScreenshots(result, OUT, [head("b")]), "note the user wrote")).toBe(1);
	});
});

// A stand-in for gh that keeps one PR in a state file and, like GitHub,
// swaps each attached file's path in the posted body for an upload URL.
// FAKE_GH_SKIP names a path it leaves unswapped; FAKE_GH_FAIL makes an
// edit that attaches files exit 1 after saving, as gh does when only
// some uploads fail; FAKE_GH_DIE makes an edit exit 1 before saving.
const FAKE_GH = `#!/usr/bin/env bun
import { readFileSync, writeFileSync } from "node:fs";
import { basename } from "node:path";
const args = process.argv.slice(2);
const file = process.env.FAKE_GH_STATE;
const pr = JSON.parse(readFileSync(file, "utf8"));
if (args[0] !== "pr") process.exit(2);
if (args[1] === "view" && args.includes("-q")) console.log(pr.number);
else if (args[1] === "view") console.log(JSON.stringify({ body: pr.body }));
else if (args[1] === "edit") {
	if (process.env.FAKE_GH_DIE) process.exit(1);
	let body = readFileSync(args[args.indexOf("--body-file") + 1], "utf8");
	const attached = args.flatMap((a, i) => (a === "--attach" ? [args[i + 1]] : []));
	for (const path of attached) {
		if (path !== process.env.FAKE_GH_SKIP) body = body.replaceAll(path, "https://uploads.invalid/" + basename(path));
	}
	pr.body = body;
	pr.edits.push(args.slice(2));
	writeFileSync(file, JSON.stringify(pr));
	if (attached.length > 0 && process.env.FAKE_GH_FAIL) process.exit(1);
} else process.exit(2);
`;

describe("with a PR on a stand-in gh", () => {
	let dir: string;
	const saved = { PATH: process.env.PATH };

	const post = (body: string, number = 7) =>
		writeFileSync(process.env.FAKE_GH_STATE as string, JSON.stringify({ number, body, edits: [] }));
	const pr = () => JSON.parse(readFileSync(process.env.FAKE_GH_STATE as string, "utf8"));

	beforeEach(() => {
		dir = mkdtempSync(join(tmpdir(), "meerkat-pr-screenshots-test-"));
		writeFileSync(join(dir, "gh"), FAKE_GH, { mode: 0o755 });
		process.env.PATH = `${dir}:${saved.PATH}`;
		process.env.FAKE_GH_STATE = join(dir, "pr.json");
	});

	afterEach(() => {
		process.env.PATH = saved.PATH;
		for (const key of ["FAKE_GH_STATE", "FAKE_GH_SKIP", "FAKE_GH_FAIL", "FAKE_GH_DIE"]) delete process.env[key];
		rmSync(dir, { recursive: true, force: true });
	});

	test("--attach is off unless given, and the PR comes from the current branch unless --pr is", () => {
		post("body", 42);

		expect(parseArgs(["steps.ts"])).toMatchObject({ pr: 42, attach: false, before: false });
		expect(parseArgs(["steps.ts", "--before", "--attach"])).toMatchObject({ pr: 42, attach: true, before: true });
		expect(parseArgs(["--pr", "9", "steps.ts", "--attach"])).toMatchObject({ pr: 9, attach: true });
	});

	test("attaching puts the shots in the description as uploads and names no local path", () => {
		post("## What\n\n- a change");
		attachShots(7, OUT, [base("a"), head("a", "look here")]);

		const { body, edits } = pr();
		expect(body.startsWith("## What\n\n- a change\n\n")).toBe(true);
		expect(body).toContain("![before a](https://uploads.invalid/base-a.png)");
		expect(body).toContain("look here\n\n![after a](https://uploads.invalid/head-a.png)");
		expect(body).not.toContain(OUT);
		expect(edits).toHaveLength(1);
		const attached = edits[0].flatMap((a: string, i: number) => (a === "--attach" ? [edits[0][i + 1]] : []));
		expect(attached).toEqual([`${OUT}/base-a.png`, `${OUT}/head-a.png`]);
	});

	test("attaching again replaces the first run's images and keeps what was written around them", () => {
		post("intro");
		attachShots(7, OUT, [head("one")]);
		post(`${pr().body.replace("intro", "intro, edited")}\n\nnotes after`);
		attachShots(7, OUT, [head("two")]);

		const { body } = pr();
		expect(body.startsWith("intro, edited\n\n")).toBe(true);
		expect(body.endsWith("\n\nnotes after")).toBe(true);
		expect(body).toContain("head-two.png");
		expect(body).not.toContain("head-one.png");
		expect(count(body, START)).toBe(1);
	});

	test("keeps the upload when the description merely mentions the shots directory", () => {
		post(`kept in ${OUT}/notes.txt`);
		attachShots(7, OUT, [head("a")]);

		expect(pr().body).toContain(`kept in ${OUT}/notes.txt`);
		expect(pr().body).toContain("https://uploads.invalid/head-a.png");
	});

	test("restores the description and fails when a local path survives the upload", () => {
		post("original body");
		process.env.FAKE_GH_SKIP = `${OUT}/head-a.png`;

		expect(() => attachShots(7, OUT, [base("a"), head("a")])).toThrow(/still named/);
		expect(pr().body).toBe("original body");
	});

	test("restores the description and reports the failure when gh saved some uploads and then failed", () => {
		post("original body");
		process.env.FAKE_GH_SKIP = `${OUT}/head-a.png`;
		process.env.FAKE_GH_FAIL = "1";

		expect(() => attachShots(7, OUT, [base("a"), head("a")])).toThrow(/still named/);
		expect(pr().body).toBe("original body");
	});

	test("reports gh's own failure and leaves the description alone when gh saved nothing", () => {
		post("original body");
		process.env.FAKE_GH_DIE = "1";

		expect(() => attachShots(7, OUT, [head("a")])).toThrow(/Command failed/);
		expect(pr().body).toBe("original body");
	});

	test("refuses a path that markdown or gh would misread, before calling gh", () => {
		post("original body");

		expect(() => attachShots(7, "/shots/with space", [head("a")])).toThrow(/can't attach/);
		expect(() => attachShots(7, "/shots/with(paren)", [head("a")])).toThrow(/can't attach/);
		expect(pr()).toEqual({ number: 7, body: "original body", edits: [] });
	});
});

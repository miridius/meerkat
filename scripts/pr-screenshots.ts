// Screenshots of a pull request's UI change, for its description.
//
//   bun scripts/pr-screenshots.ts capture <steps.ts> [--pr <N>] [--out <dir>]
//   bun scripts/pr-screenshots.ts attach [--pr <N>] [--out <dir>]
//
// `capture` reviews the PR with `meerkat --pr <N>` run by this
// checkout's `bin/meerkat-beam`, so the page shows the PR's own diff
// rendered by the PR's code. The review runs in a throwaway clone:
// review state and approvals meerkat saves under the git dir land
// there, never in this checkout. A headless Chromium opens the review
// and calls the default export of <steps.ts> with `{ page, shot }`:
//
//   export default async ({ page, shot }) => {
//     await page.getByRole("button", { name: "Split" }).click();
//     await shot("split-view", "Expand buttons in the right gutter");
//     await shot("one-hunk", "A single hunk", page.locator(".diff-hunk").first());
//   };
//
// `shot(name, alt, locator?)` saves <out>/<name>.png of the viewport,
// or of `locator` when given.
//
// `attach` uploads those PNGs with `gh pr edit --attach` and puts them
// in a Screenshots section of the PR description, replacing the one an
// earlier run added. The uploads are public.
//
// --pr defaults to the PR of the current branch, and --out to
// <tmpdir>/meerkat-pr-<N>-screenshots.

import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { chromium, type Locator, type Page } from "@playwright/test";

type Shot = { file: string; alt: string };
type Steps = (ctx: {
	page: Page;
	shot: (name: string, alt: string, locator?: Locator) => Promise<void>;
}) => Promise<void>;

const START = "<!-- pr-screenshots:start -->";
const END = "<!-- pr-screenshots:end -->";
const ROOT = resolve(import.meta.dir, "..");

function run(cmd: string, args: string[], cwd = ROOT): string {
	return execFileSync(cmd, args, { cwd, encoding: "utf8" }).trim();
}

function parseArgs(argv: string[]) {
	const [mode, ...rest] = argv;
	const opts: { pr?: number; out?: string; steps?: string } = {};
	for (let i = 0; i < rest.length; i++) {
		if (rest[i] === "--pr") opts.pr = Number(rest[++i]);
		else if (rest[i] === "--out") opts.out = resolve(rest[++i]);
		else if (mode === "capture" && !opts.steps) opts.steps = resolve(rest[i]);
		else throw new Error(`unexpected argument: ${rest[i]}`);
	}
	if (mode !== "capture" && mode !== "attach") {
		throw new Error("usage: bun scripts/pr-screenshots.ts capture <steps.ts> | attach [--pr N] [--out DIR]");
	}
	if (mode === "capture" && !opts.steps) throw new Error("capture needs a steps file");
	const pr = opts.pr ?? Number(run("gh", ["pr", "view", "--json", "number", "-q", ".number"], process.cwd()));
	if (!Number.isInteger(pr) || pr <= 0) throw new Error(`not a PR number: ${pr}`);
	return { mode, pr, steps: opts.steps, out: opts.out ?? join(tmpdir(), `meerkat-pr-${pr}-screenshots`) };
}

async function capture(pr: number, stepsPath: string, out: string): Promise<void> {
	const steps: Steps = (await import(stepsPath)).default;
	rmSync(out, { recursive: true, force: true });
	mkdirSync(out, { recursive: true });

	// A local clone shares this checkout's objects; pointing its origin
	// at GitHub lets `meerkat --pr` fetch the PR's refs.
	const clone = mkdtempSync(join(tmpdir(), "meerkat-pr-screenshots-"));
	run("git", ["clone", "--quiet", "--no-checkout", ROOT, clone]);
	run("git", ["-C", clone, "remote", "set-url", "origin", run("git", ["-C", ROOT, "remote", "get-url", "origin"])]);

	// The runner reads MEERKAT_BIN when it loads.
	process.env.MEERKAT_BIN = join(ROOT, "bin", "meerkat-beam");
	const { startMeerkat } = await import("../tests/e2e/lib/runner.ts");
	const meerkat = await startMeerkat({
		args: ["--pr", String(pr)],
		fixture: { dir: clone, cleanup: () => rmSync(clone, { recursive: true, force: true }) },
	});

	const browser = await chromium.launch({ headless: true });
	const shots: Shot[] = [];
	try {
		const page = await browser.newPage({ viewport: { width: 1400, height: 900 }, deviceScaleFactor: 2 });
		await page.goto(meerkat.url);
		// Clicks before LiveView joins its channel are dropped.
		await page.waitForFunction(
			() => document.querySelector("[data-phx-main]")?.classList.contains("phx-connected") === true,
			undefined,
			{ timeout: 45_000 },
		);
		await steps({
			page,
			shot: async (name, alt, locator) => {
				const file = `${name}.png`;
				await (locator ?? page).screenshot({ path: join(out, file) });
				shots.push({ file, alt });
			},
		});
	} finally {
		await browser.close();
		await meerkat.kill();
	}
	if (shots.length === 0) throw new Error("the steps file took no screenshots");
	writeFileSync(join(out, "shots.json"), JSON.stringify(shots, null, 1));
	for (const s of shots) console.log(join(out, s.file));
}

// Replaces the section between the markers, or puts a new one before a
// trailing italic line such as `_Written by …_`, or at the end.
function withScreenshots(body: string, shots: Shot[]): string {
	const images = shots.map((s) => `![${s.alt}](./${s.file})`).join("\n\n");
	const section = `${START}\n## Screenshots\n\n${images}\n${END}`;
	const start = body.indexOf(START);
	const end = body.indexOf(END);
	if (start !== -1 && end > start) return body.slice(0, start) + section + body.slice(end + END.length);
	const trimmed = body.trimEnd();
	const attribution = trimmed.match(/\n+(_[^\n]+_)$/);
	if (attribution?.index !== undefined) {
		return `${trimmed.slice(0, attribution.index)}\n\n${section}\n\n${attribution[1]}\n`;
	}
	return `${trimmed}\n\n${section}\n`;
}

function attach(pr: number, out: string): void {
	const shots: Shot[] = JSON.parse(readFileSync(join(out, "shots.json"), "utf8"));
	const repo = run("gh", ["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"]);
	const body = run("gh", ["pr", "view", String(pr), "-R", repo, "--json", "body", "-q", ".body"]);
	writeFileSync(join(out, "body.md"), withScreenshots(body, shots));
	// gh uploads each file and rewrites its `./<file>` reference in the
	// body to the uploaded asset's URL; paths resolve against `out`.
	const attachArgs = shots.flatMap((s) => ["--attach", `./${s.file}`]);
	console.log(run("gh", ["pr", "edit", String(pr), "-R", repo, "--body-file", "body.md", ...attachArgs], out));
}

if (import.meta.main) {
	const { mode, pr, steps, out } = parseArgs(process.argv.slice(2));
	if (mode === "capture") await capture(pr, steps as string, out);
	else attach(pr, out);
}

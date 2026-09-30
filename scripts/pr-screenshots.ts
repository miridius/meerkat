// Screenshots of a pull request's UI change, for its description.
//
//   bun scripts/pr-screenshots.ts capture <steps.ts> [--before] [--pr <N>] [--out <dir>]
//   bun scripts/pr-screenshots.ts attach [--pr <N>] [--out <dir>]
//
// `capture` reviews the PR with `meerkat --pr <N>`, so the page shows
// the PR's own diff, rendered by meerkat built from the PR's head
// commit. With `--before` it also runs the same steps against meerkat
// built from the commit the PR branches from, for a before/after pair.
// Both builds are fresh clones in a temp dir, so the PR branch needn't
// be checked out here, and the reviews run in throwaway clones, so
// review state and approvals never land in this checkout. Settings
// from MEERKAT_* variables in your environment are dropped, so the page
// looks the way it does by default. Each run builds meerkat from
// scratch, which takes about a minute.
//
// A headless Chromium opens each review and calls the default export
// of <steps.ts>:
//
//   export default async ({ page, shot, expect, code }) => {
//     await page.getByRole("button", { name: "Split" }).click();
//     await shot("split-view", "Expand buttons sit in the right-hand gutter");
//     if (code === "head") {
//       await shot("footer", "Each open form is a link", page.locator("footer"));
//     }
//   };
//
// This file exports the `Steps` type of that function.
// `code` is "head" or "base", so the steps can skip a shot of UI the
// base code lacks or word a caption for each. `shot(name, caption,
// locator?)` saves the viewport, or just `locator` when given. The
// caption is shown above the image in the description: say what the
// image shows and, where it isn't obvious, what to look at. A base and
// head shot with the same name are shown as a Before/After pair.
//
// Two things the steps file has to do itself:
// - Import `@playwright/test` only as a type (`import type`). A runtime
//   import from a steps file outside this checkout loads a second copy
//   and throws "Requiring @playwright/test
//   second time"; use the `expect` passed in instead.
// - Scroll a line clear of the sticky file header before opening a form
//   on it or taking its screenshot, e.g.
//   `await line.evaluate((el) => el.scrollIntoView({ block: "center" }))`;
//   otherwise the header can cover it.
//
// `attach` uploads the PNGs with `gh pr edit --attach` and puts them in
// a Screenshots section of the PR description, replacing the one an
// earlier run added. The uploads are public.
//
// --pr defaults to the PR of the current branch, and --out to
// <tmpdir>/meerkat-pr-<N>-screenshots.

import { spawn, execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { type Browser, chromium, expect, type Locator, type Page } from "@playwright/test";

export type Code = "base" | "head";
export type Shot = { name: string; code: Code; file: string; caption: string };
export type Steps = (ctx: {
	page: Page;
	shot: (name: string, caption: string, locator?: Locator) => Promise<void>;
	expect: typeof expect;
	code: Code;
}) => Promise<void>;

const START = "<!-- pr-screenshots:start -->";
const END = "<!-- pr-screenshots:end -->";
const ROOT = resolve(import.meta.dir, "..");

function run(cmd: string, args: string[], cwd = ROOT): string {
	return execFileSync(cmd, args, { cwd, encoding: "utf8" }).trim();
}

// Like `run`, but lets two builds proceed at once, and shows the
// command's output only if it fails.
function runAsync(cmd: string, args: string[], cwd: string, env: NodeJS.ProcessEnv): Promise<void> {
	return new Promise((done, fail) => {
		const proc = spawn(cmd, args, { cwd, env, stdio: ["ignore", "pipe", "pipe"] });
		let output = "";
		proc.stdout.on("data", (chunk) => (output += chunk));
		proc.stderr.on("data", (chunk) => (output += chunk));
		proc.on("error", fail);
		proc.on("close", (code) =>
			code === 0 ? done() : fail(new Error(`${cmd} ${args.join(" ")} failed in ${cwd}:\n${output}`)),
		);
	});
}

function parseArgs(argv: string[]) {
	const [mode, ...rest] = argv;
	const opts: { pr?: number; out?: string; steps?: string; before: boolean } = { before: false };
	for (let i = 0; i < rest.length; i++) {
		if (rest[i] === "--pr") opts.pr = Number(rest[++i]);
		else if (rest[i] === "--out") opts.out = resolve(rest[++i]);
		else if (rest[i] === "--before" && mode === "capture") opts.before = true;
		else if (mode === "capture" && !opts.steps) opts.steps = resolve(rest[i]);
		else throw new Error(`unexpected argument: ${rest[i]}`);
	}
	if (mode !== "capture" && mode !== "attach") {
		throw new Error(
			"usage: bun scripts/pr-screenshots.ts capture <steps.ts> [--before] | attach  [--pr N] [--out DIR]",
		);
	}
	if (mode === "capture" && !opts.steps) throw new Error("capture needs a steps file");
	const pr = opts.pr ?? Number(run("gh", ["pr", "view", "--json", "number", "-q", ".number"], process.cwd()));
	if (!Number.isInteger(pr) || pr <= 0) throw new Error(`not a PR number: ${pr}`);
	return {
		mode,
		pr,
		steps: opts.steps,
		before: opts.before,
		out: opts.out ?? join(tmpdir(), `meerkat-pr-${pr}-screenshots`),
	};
}

// Clones meerkat at `sha` into `dir`, on a branch named `branch` so the
// page's version chip reads `dev: <branch>`, and builds it the way
// bin/meerkat-beam would, so its first launch doesn't compile.
async function build(src: string, sha: string, branch: string, dir: string): Promise<void> {
	run("git", ["clone", "--quiet", "--no-checkout", src, dir]);
	run("git", ["-C", dir, "checkout", "--quiet", "-B", branch, sha]);
	const env = { ...process.env, MIX_ENV: "dev" };
	await runAsync("mix", ["deps.get"], dir, env);
	// --ignore-scripts skips `lefthook install`, whose hooks would run
	// on this clone's git operations.
	await runAsync("pnpm", ["install", "--frozen-lockfile", "--ignore-scripts"], dir, env);
	await runAsync("mix", ["compile", "--no-warnings-as-errors"], dir, env);
	await runAsync("bunx", ["vite", "build"], join(dir, "assets"), {
		...env,
		MIX_BUILD_PATH: join(dir, "_build", "dev"),
	});
}

async function capture(pr: number, stepsPath: string, out: string, before: boolean): Promise<void> {
	const steps: Steps = (await import(stepsPath)).default;
	rmSync(out, { recursive: true, force: true });
	mkdirSync(out, { recursive: true });

	// Meerkat reads MEERKAT_* settings from the environment it inherits,
	// such as a review timeout that would show in the page's countdown.
	for (const key of Object.keys(process.env)) {
		if (key.startsWith("MEERKAT_")) delete process.env[key];
	}

	const origin = run("git", ["-C", ROOT, "remote", "get-url", "origin"]);
	const { headRefName, baseRefName } = JSON.parse(
		run("gh", ["pr", "view", String(pr), "--json", "headRefName,baseRefName"]),
	);
	const work = mkdtempSync(join(tmpdir(), "meerkat-pr-screenshots-"));
	let browser: Browser | undefined;
	const shots: Shot[] = [];
	try {
		// A local clone shares this checkout's objects; fetching from
		// GitHub adds the PR's commits.
		const src = join(work, "src.git");
		run("git", ["clone", "--quiet", "--bare", ROOT, src]);
		run("git", ["-C", src, "remote", "set-url", "origin", origin]);
		run("git", [
			"-C",
			src,
			"fetch",
			"--quiet",
			"origin",
			`+refs/pull/${pr}/head:refs/pr/head`,
			`+refs/heads/${baseRefName}:refs/pr/base`,
		]);
		const commits: { code: Code; sha: string; branch: string }[] = [
			{ code: "head", sha: run("git", ["-C", src, "rev-parse", "refs/pr/head"]), branch: headRefName },
		];
		if (before) {
			const sha = run("git", ["-C", src, "merge-base", "refs/pr/base", "refs/pr/head"]);
			commits.unshift({ code: "base", sha, branch: baseRefName });
		}
		console.error(`building meerkat at ${commits.map((c) => `${c.code} ${c.sha.slice(0, 7)}`).join(", ")}…`);
		await Promise.all(commits.map((c) => build(src, c.sha, c.branch, join(work, c.code))));

		const { startMeerkat } = await import("../tests/e2e/lib/runner.ts");
		browser = await chromium.launch({ headless: true });
		for (const { code } of commits) {
			const reviewDir = join(work, `review-${code}`);
			run("git", ["clone", "--quiet", "--no-checkout", src, reviewDir]);
			// `meerkat --pr` fetches the PR from origin.
			run("git", ["-C", reviewDir, "remote", "set-url", "origin", origin]);
			const meerkat = await startMeerkat({
				bin: join(work, code, "bin", "meerkat-beam"),
				args: ["--pr", String(pr)],
				fixture: { dir: reviewDir },
				env: { MIX_ENV: "dev" },
			});
			// A context of its own, so settings the base review saves in
			// the browser don't carry over to the head one.
			const context = await browser.newContext({ viewport: { width: 1400, height: 900 }, deviceScaleFactor: 2 });
			try {
				const page = await context.newPage();
				await page.goto(meerkat.url);
				// Clicks before LiveView joins its channel are dropped.
				await page.waitForFunction(
					() => document.querySelector("[data-phx-main]")?.classList.contains("phx-connected") === true,
					undefined,
					{ timeout: 45_000 },
				);
				await steps({
					page,
					expect,
					code,
					shot: async (name, caption, locator) => {
						if (!/^[\w-]+$/.test(name)) throw new Error(`shot name must be [A-Za-z0-9_-]+: ${name}`);
						if (shots.some((s) => s.code === code && s.name === name)) {
							throw new Error(`two ${code} shots named ${name}`);
						}
						const file = `${code}-${name}.png`;
						await (locator ?? page).screenshot({ path: join(out, file) });
						shots.push({ name, code, file, caption });
					},
				});
			} finally {
				await context.close();
				await meerkat.kill();
			}
		}
	} finally {
		await browser?.close();
		rmSync(work, { recursive: true, force: true });
	}
	if (shots.length === 0) throw new Error("the steps file took no screenshots");
	writeFileSync(join(out, "shots.json"), JSON.stringify(shots, null, 1));
	for (const s of shots) console.log(join(out, s.file));
}

// Each caption as a paragraph above its image. A base and head shot of
// the same name go together, base first, labelled Before and After;
// the order is that of the head shots, then any base-only ones.
export function section(shots: Shot[]): string {
	const names = [...new Set([...shots.filter((s) => s.code === "head"), ...shots].map((s) => s.name))];
	const blocks = names.map((name) => {
		const base = shots.find((s) => s.code === "base" && s.name === name);
		const head = shots.find((s) => s.code === "head" && s.name === name);
		const label = (s: Shot) => (base && head ? `**${s === base ? "Before" : "After"}:** ` : "");
		return [base, head]
			.filter((s): s is Shot => s !== undefined)
			.map((s) => `${label(s)}${s.caption}\n\n![${alt(s.caption)}](./${s.file})`)
			.join("\n\n");
	});
	return `${START}\n## Screenshots\n\n${blocks.join("\n\n")}\n${END}`;
}

function alt(caption: string): string {
	return caption.replace(/\s+/g, " ").replace(/[[\]`]/g, "");
}

// Replaces the section between the markers, or puts a new one before a
// trailing italic line such as `_Written by …_`, or at the end.
export function withScreenshots(body: string, shots: Shot[]): string {
	const replacement = section(shots);
	const start = body.indexOf(START);
	const end = body.indexOf(END);
	if (start !== -1 && end > start) return body.slice(0, start) + replacement + body.slice(end + END.length);
	const trimmed = body.trimEnd();
	const attribution = trimmed.match(/\n+(_[^\n]+_)$/);
	if (attribution?.index !== undefined) {
		return `${trimmed.slice(0, attribution.index)}\n\n${replacement}\n\n${attribution[1]}\n`;
	}
	return `${trimmed}\n\n${replacement}\n`;
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
	const { mode, pr, steps, out, before } = parseArgs(process.argv.slice(2));
	if (mode === "capture") await capture(pr, steps as string, out, before);
	else attach(pr, out);
}

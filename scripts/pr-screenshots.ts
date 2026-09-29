// Screenshots of a pull request's UI change, for its description.
//
//   bun scripts/pr-screenshots.ts <steps.ts> [--before] [--pr <N>] [--out <dir>]
//
// This reviews the PR with `meerkat --pr <N>`, so the page shows
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
//     await shot("split-view");
//     if (code === "head") {
//       await shot("footer", { locator: page.locator("footer"), caption: "the form links" });
//     }
//   };
//
// This file exports the `Steps` type of that function.
// `code` is "head" or "base", so the steps can skip a shot of UI the
// base code lacks. `shot(name, { locator?, caption? })` saves the
// viewport, or just `locator` when given. Give a caption only when a
// reviewer wouldn't otherwise know what to look at, as one short line.
// Shots are saved as <code>-<name>.png, so a base and head shot with the
// same name make a before/after pair.
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
// It prints one line per shot: the PNG's path, then its caption if it
// has one. To put shots in the PR description, reference each by that
// path, as in `![the split view](<path>)`, and post the description
// with `gh pr edit --body-file <file>` and one `--attach <path>` per
// shot. gh uploads each attached file and rewrites its references to
// the uploaded image; it appends a file attached but never referenced.
// The uploads are public.
//
// --pr defaults to the PR of the current branch, and --out to
// <tmpdir>/meerkat-pr-<N>-screenshots.

import { spawn, execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { type Browser, chromium, expect, type Locator, type Page } from "@playwright/test";

export type Code = "base" | "head";
type Shot = { name: string; code: Code; file: string; caption?: string };
export type Steps = (ctx: {
	page: Page;
	shot: (name: string, opts?: { locator?: Locator; caption?: string }) => Promise<void>;
	expect: typeof expect;
	code: Code;
}) => Promise<void>;

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
	const opts: { pr?: number; out?: string; steps?: string; before: boolean } = { before: false };
	for (let i = 0; i < argv.length; i++) {
		if (argv[i] === "--pr") opts.pr = Number(argv[++i]);
		else if (argv[i] === "--out") opts.out = resolve(argv[++i]);
		else if (argv[i] === "--before") opts.before = true;
		else if (!opts.steps) opts.steps = resolve(argv[i]);
		else throw new Error(`unexpected argument: ${argv[i]}`);
	}
	if (!opts.steps) {
		throw new Error("usage: bun scripts/pr-screenshots.ts <steps.ts> [--before] [--pr N] [--out DIR]");
	}
	const pr = opts.pr ?? Number(run("gh", ["pr", "view", "--json", "number", "-q", ".number"], process.cwd()));
	if (!Number.isInteger(pr) || pr <= 0) throw new Error(`not a PR number: ${pr}`);
	return {
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
					shot: async (name, { locator, caption } = {}) => {
						if (!/^[\w-]+$/.test(name)) throw new Error(`shot name must be [A-Za-z0-9_-]+: ${name}`);
						if (caption?.includes("\n")) throw new Error(`caption of ${name} must be one line`);
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
	for (const s of shots) console.log([join(out, s.file), s.caption].filter(Boolean).join(" "));
}

if (import.meta.main) {
	const { pr, steps, out, before } = parseArgs(process.argv.slice(2));
	await capture(pr, steps as string, out, before);
}

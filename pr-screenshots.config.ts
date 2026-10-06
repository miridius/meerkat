// How the `/pr` screenshot script builds and serves meerkat at a commit.
// The script runs `build` in a fresh clone, then `start` serves a review of
// the PR from that clone's `bin/meerkat-beam`.

import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { startMeerkat } from "./tests/e2e/lib/runner.ts";

type Exec = (
	cmd: string,
	args: string[],
	opts?: { cwd?: string; env?: NodeJS.ProcessEnv },
) => Promise<void>;

export default {
	build: async ({ dir, exec }: { dir: string; exec: Exec }) => {
		const env = { ...process.env, MIX_ENV: "dev" };
		await exec("mix", ["deps.get"], { env });
		await exec("pnpm", ["install", "--frozen-lockfile", "--ignore-scripts"], { env });
		await exec("mix", ["compile", "--no-warnings-as-errors"], { env });
		await exec("bunx", ["vite", "build"], {
			cwd: join(dir, "assets"),
			env: { ...env, MIX_BUILD_PATH: join(dir, "_build", "dev") },
		});
	},

	start: async ({
		dir,
		code,
		pr,
		origin,
		src,
		work,
	}: {
		dir: string;
		code: string;
		pr: number;
		origin: string;
		src: string;
		work: string;
	}) => {
		// Meerkat reads MEERKAT_* settings from the environment it inherits,
		// such as a review timeout that would show in the page's countdown.
		for (const key of Object.keys(process.env)) {
			if (key.startsWith("MEERKAT_")) delete process.env[key];
		}
		// `meerkat --pr` looks up the PR with gh and fetches it from origin.
		// The build clone's origin is the local `src`, so review from a
		// throwaway clone whose origin is the real one.
		const reviewDir = join(work, `review-${code}`);
		execFileSync("git", ["clone", "--quiet", src, reviewDir]);
		execFileSync("git", ["remote", "set-url", "origin", origin], { cwd: reviewDir });
		const runner = await startMeerkat({
			bin: join(dir, "bin", "meerkat-beam"),
			args: ["--pr", String(pr)],
			fixture: { dir: reviewDir },
			env: { MIX_ENV: "dev" },
		});
		return { url: runner.url, stop: runner.kill };
	},

	ready: async (page: {
		waitForSelector: (selector: string, opts: { timeout: number }) => Promise<unknown>;
	}) => {
		await page.waitForSelector("[data-phx-main].phx-connected", { timeout: 45_000 });
	},
};

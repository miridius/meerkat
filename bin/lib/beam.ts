// Dev launcher: runs meerkat from this checkout under Mix. Wraps `mix
// run` in a shepherd loop so the BEAM can self-halt with exit code 75 to
// restart onto a new version (only when `MEERKAT_CURRENT_LINK` is set, as
// the e2e restart test does) and the launcher respawns it, preferring the
// port it bound. The user's browser sees a brief WebSocket drop + LV
// auto-reconnects to the new BEAM; `ReviewServer.init` reloads
// in-progress comments via `Meerkat.Persistence`.
//
// The e2e suite runs this launcher: `bun run test:e2e` always, and a bare
// `bunx playwright test` unless `MEERKAT_BIN` names another.
//
// It works from the Mix project root so `mix run` works, but captures the
// caller's cwd in $MEERKAT_PWD so `Meerkat.CLI` reads git state from the
// right tree.

import { lstatSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { attach, say } from "./attach.ts";
import { CLI_HALT, requireAnswersInput, runOnce, selfCommand, serve, status, wantsAnswers } from "./serve.ts";

// The checkout: Bun names it by its physical path.
const ROOT = resolve(import.meta.dir, "../..");

// Whether any file under `paths`, taken from the checkout, has a newer
// mtime than `than`. Stops at the first one. Like `find`, it follows no
// symlink, so a link cycle cannot trap it.
export function anyNewer(root: string, paths: string[], than: number): boolean {
	const newer = (path: string): boolean => {
		let stat: ReturnType<typeof lstatSync>;
		try {
			stat = lstatSync(path);
		} catch {
			return false;
		}
		if (stat.mtimeMs > than) return true;
		if (!stat.isDirectory()) return false;
		let names: string[] = [];
		try {
			names = readdirSync(path);
		} catch {}
		return names.some((name) => newer(join(path, name)));
	};
	return paths.some((path) => newer(join(root, path)));
}

const mtime = (path: string): number | null => {
	try {
		return statSync(path).mtimeMs;
	} catch {
		return null;
	}
};

// Runs `command` with its stdout sent to stderr, as the launcher's own
// stdout is the caller's, and returns its exit status.
function run(command: string[], cwd: string, env: Record<string, string | undefined> = process.env): number {
	const result = Bun.spawnSync(command, { cwd, env, stdio: ["inherit", 2, "inherit"] });
	return status(result);
}

// Pre-compile guard. Cheap when the build is warm: the walk stops at the
// first newer file. A new worktree's build is copied from the main
// checkout after its sources are checked out, so it can look newer than
// sources it was not compiled from; a stamp naming the checkout whose
// launcher last compiled the build makes the first launch in any other
// checkout run `mix compile`, which decides what is stale. Returns the
// compile's exit status.
export function precompileIfStale(root: string, mixEnv: string): number {
	const lock = join(root, `_build/${mixEnv}/lib/meerkat/.mix/compile.elixir`);
	const stamp = join(root, `_build/${mixEnv}/.meerkat-root`);
	const locked = mtime(lock);
	let stamped: string | null = null;
	try {
		stamped = readFileSync(stamp, "utf8").replace(/\n+$/, "");
	} catch {}
	if (locked !== null && stamped === root && !anyNewer(root, ["lib", "config", "mix.exs", "mix.lock"], locked)) return 0;
	const code = run(["mix", "compile", "--no-warnings-as-errors"], root);
	if (code === 0) {
		try {
			writeFileSync(stamp, `${root}\n`);
		} catch {}
	}
	return code;
}

// Asset build — same guard.
export function buildAssetsIfStale(root: string, mixEnv: string): number {
	const built = mtime(join(root, "priv/static/.vite/manifest.json"));
	if (
		built !== null &&
		!anyNewer(
			root,
			["assets/svelte", "assets/js", "assets/css", "assets/ts", "assets/package.json", "pnpm-lock.yaml"],
			built,
		)
	)
		return 0;
	return run(["bunx", "vite", "build"], join(root, "assets"), {
		...process.env,
		MIX_BUILD_PATH: join(root, `_build/${mixEnv}`),
	});
}

export async function main(args: string[]): Promise<never> {
	const origPwd = process.cwd();
	process.chdir(ROOT);
	process.env.MIX_ENV ||= "dev";
	process.env.MEERKAT_PWD = origPwd;
	const mixEnv = process.env.MIX_ENV;

	// The e2e suite's global setup builds once through the same guards
	// before its parallel workers each boot this launcher.
	if (process.env.MEERKAT_BUILD_ONLY) {
		const code = precompileIfStale(ROOT, mixEnv);
		process.exit(code === 0 ? buildAssetsIfStale(ROOT, mixEnv) : code);
	}

	const beam = [
		"mix",
		"run",
		"--no-start",
		"--no-compile",
		"-e",
		`File.cd!(System.get_env("MEERKAT_PWD") || "."); ${CLI_HALT}`,
		"--",
		...args,
	];

	// `--answers` reads the answers from stdin, so it runs once, with the
	// caller's stdin, with no restart to re-read a stdin already consumed.
	if (wantsAnswers(args)) {
		requireAnswersInput();
		if (precompileIfStale(ROOT, mixEnv) !== 0) {
			say(
				"meerkat: the build is broken, so the answers were not stored; fix the compile error above and re-run.\n",
			);
			process.exit(2);
		}
		return runOnce(beam);
	}

	// Run as the caller, which re-runs this launcher detached, with
	// MEERKAT_SERVE_DIR set, to serve the review. The re-run takes the
	// user's repo from its working directory.
	if (!process.env.MEERKAT_SERVE_DIR) {
		process.chdir(origPwd);
		return attach(selfCommand(), args, origPwd);
	}

	// `--no-start` keeps the OTP app stopped so `Meerkat.CLI.main` can
	// put_env dynamic config BEFORE the endpoint binds.
	return serve({
		args,
		beforeEach() {
			if (precompileIfStale(ROOT, mixEnv) !== 0 || buildAssetsIfStale(ROOT, mixEnv) !== 0) {
				say("meerkat: the build failed — defaulting to REJECT (commit aborted).\n");
				process.exit(2);
			}
		},
		beamCommand: () => beam,
		restarting: "meerkat: restarting...",
	});
}

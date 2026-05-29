import { spawn } from "node:child_process";
import { delimiter } from "node:path";
import { type Fixture, makeFixture } from "./fixture.js";

const MEERKAT_BIN = process.env.MEERKAT_BIN ?? "meerkat";

export type RunnerOpts = {
	// Args to pass to meerkat (default: --commit-msg <fixture.commitMsgPath>).
	args?: string[];
	// Override fixture; if absent we make one with realistic defaults.
	// Accepts the regular Fixture or any object exposing `dir` and an
	// optional `cleanup` (e.g. PrFixture).
	fixture?: { dir: string; cleanup?: () => void } & Partial<Fixture>;
	// Extra paths to PREPEND to PATH (e.g. a stub `gh` binary directory).
	pathPrefixes?: string[];
	// If true, the fixture's `cleanup()` is NOT invoked on exit (debugging).
	keepFixture?: boolean;
};

export type Runner = {
	url: string;
	fixture: { dir: string; cleanup?: () => void } & Partial<Fixture>;
	// Resolves with {code, stderr} when meerkat exits.
	awaitExit: () => Promise<{ code: number | null; stderr: string }>;
	kill: () => Promise<void>;
};

const URL_RE = /meerkat: review UI at (https?:\/\/[^\s]+)/;

// Spawn meerkat against a fixture, parse the URL from stderr, hand back
// a runner the test can drive. Tests should `await runner.awaitExit()`
// (or call `runner.kill()` from a `finally`) so the fixture's cleanup
// runs.
export async function startMeerkat(opts: RunnerOpts = {}): Promise<Runner> {
	const fixture = opts.fixture ?? makeFixture();
	// The default `--commit-msg` path requires a regular Fixture; PR
	// fixtures (which set their own args) don't have one.
	const args =
		opts.args ??
		(fixture.commitMsgPath
			? ["--commit-msg", fixture.commitMsgPath]
			: (() => {
					throw new Error("startMeerkat: fixture has no commitMsgPath; pass `args` explicitly");
				})());

	const env = { ...process.env };
	if (opts.pathPrefixes && opts.pathPrefixes.length > 0) {
		env.PATH = [...opts.pathPrefixes, env.PATH ?? ""].join(delimiter);
	}

	const proc = spawn(MEERKAT_BIN, [...args, "--no-open", "--port", "0"], {
		cwd: fixture.dir,
		stdio: ["ignore", "pipe", "pipe"],
		env,
	});

	let stderrBuf = "";
	const url = await new Promise<string>((resolve, reject) => {
		// Generous; --pr mode does a `gh pr view` + `git fetch` round
		// trip before the server binds, and parallel BEAM cold-starts
		// across the worker pool can stretch wall-clock past 20s on
		// loaded machines.
		const timeoutHandle = setTimeout(
			() => reject(new Error(`timed out waiting for meerkat URL\nstderr so far:\n${stderrBuf}`)),
			40_000,
		);
		const onErr = (chunk: Buffer) => {
			stderrBuf += chunk.toString("utf8");
			const m = stderrBuf.match(URL_RE);
			if (m) {
				clearTimeout(timeoutHandle);
				proc.stderr?.off("data", onErr);
				resolve(m[1]);
			}
		};
		proc.stderr?.on("data", onErr);
		proc.once("exit", (code) => {
			clearTimeout(timeoutHandle);
			reject(
				new Error(
					`meerkat exited (code=${code}) before printing review URL\nstderr:\n${stderrBuf}`,
				),
			);
		});
	});

	// Once the URL is captured, keep buffering stderr so the test can
	// inspect feedback after decision.
	proc.stderr?.on("data", (chunk: Buffer) => {
		stderrBuf += chunk.toString("utf8");
	});

	const exitPromise = new Promise<{ code: number | null; stderr: string }>((resolve) => {
		proc.once("exit", (code) => {
			if (!opts.keepFixture) {
				fixture.cleanup?.();
			}
			resolve({ code, stderr: stderrBuf });
		});
	});

	return {
		url,
		fixture,
		awaitExit: () => exitPromise,
		kill: async () => {
			if (!proc.killed) proc.kill("SIGTERM");
			await exitPromise;
		},
	};
}

import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { type Fixture, makeFixture } from "./fixture.js";

export const MEERKAT_BIN = process.env.MEERKAT_BIN ?? "meerkat";

export type RunnerOpts = {
	// Args to pass to meerkat (default: --commit-msg <fixture.commitMsgPath>).
	args?: string[];
	// Override fixture; if absent we make one with realistic defaults.
	// Accepts the regular Fixture or any object exposing `dir` and an
	// optional `cleanup` (e.g. PrFixture).
	fixture?: { dir: string; cleanup?: () => void } & Partial<Fixture>;
	// Extra paths to PREPEND to PATH (e.g. a stub `gh` binary directory).
	pathPrefixes?: string[];
	// Extra env vars for the meerkat process (e.g. RELEASE_ROOT to point
	// Meerkat.Version at a baked manifest).
	env?: Record<string, string>;
	// If true, the fixture's `cleanup()` is NOT invoked on exit (debugging).
	keepFixture?: boolean;
	// Another runner's `runsDir`, so this run reattaches to its backend.
	runsDir?: string;
	// Run meerkat as a child of `sh`, like in a git hook, so `killParent` can kill the shell alone and leave meerkat running.
	underParent?: boolean;
	// When false, return without waiting for the review URL, for runs that exit without printing one (such as collecting a decision already made).
	awaitUrl?: boolean;
	// Starts meerkat as its own process-group leader, so `signalGroup` can signal it.
	ownGroup?: boolean;
};

export type Runner = {
	url: string;
	fixture: { dir: string; cleanup?: () => void } & Partial<Fixture>;
	// Resolves with {code, stderr} when meerkat exits.
	awaitExit: () => Promise<{ code: number | null; stderr: string }>;
	// Stops the detached backends in `runsDir` as well as the caller.
	kill: () => Promise<void>;
	// SIGKILLs the caller alone; its backend keeps serving the review.
	killCaller: () => Promise<void>;
	// SIGKILLs the `sh` running meerkat under `underParent`, leaving meerkat running.
	killParent: () => Promise<void>;
	// Signals meerkat's whole process group (requires `ownGroup`), as the caller's parent app does when signaling its process tree.
	signalGroup: (signal: NodeJS.Signals) => void;
	// Resolves once meerkat and every process holding its stderr pipe have exited.
	awaitClose: () => Promise<void>;
	runsDir: string;
};

const OWNED_RUNS_DIR_RE = /^meerkat-runs-(\d+)-[A-Za-z0-9]+$/;

const URL_RE = /Paused for human review at (https?:\/\/[^\s]+)/;

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

	const runsDir = opts.runsDir ?? mkdtempSync(join(tmpdir(), `meerkat-runs-${process.pid}-`));
	const env = { ...process.env, MEERKAT_RUNS_DIR: runsDir, ...opts.env };
	if (opts.pathPrefixes && opts.pathPrefixes.length > 0) {
		env.PATH = [...opts.pathPrefixes, env.PATH ?? ""].join(delimiter);
	}

	const argv = [MEERKAT_BIN, ...args, "--no-open", "--port", "0"];
	// sh -c execs its script's last command in place of itself; trailing `exit $?` keeps it alive as meerkat's parent.
	const [cmd, ...cmdArgs] = opts.underParent ? ["sh", "-c", '"$@"; exit $?', "sh", ...argv] : argv;
	const proc = spawn(cmd, cmdArgs, {
		cwd: fixture.dir,
		stdio: ["ignore", "pipe", "pipe"],
		env,
		detached: opts.ownGroup,
	});

	const closePromise = new Promise<void>((resolve) => proc.once("close", () => resolve()));
	let stderrBuf = "";
	const url = await new Promise<string>((resolve, reject) => {
		if (opts.awaitUrl === false) {
			resolve("");
			return;
		}
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
	}).catch(async (e) => {
		// No Runner reaches the caller, so nothing else would stop the
		// backend, which can sit waiting for a source change forever.
		await stopBackends(runsDir);
		if (proc.exitCode === null && proc.signalCode === null) proc.kill("SIGTERM");
		if (!opts.keepFixture) fixture.cleanup?.();
		if (opts.runsDir === undefined) rmSync(runsDir, { recursive: true, force: true });
		throw e;
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
			await stopBackends(runsDir);
			if (proc.exitCode === null && proc.signalCode === null) proc.kill("SIGTERM");
			await exitPromise;
			if (opts.runsDir === undefined) rmSync(runsDir, { recursive: true, force: true });
		},
		killCaller: async () => {
			proc.kill("SIGKILL");
			await exitPromise;
		},
		killParent: async () => {
			if (!opts.underParent) throw new Error("killParent: start the runner with underParent");
			proc.kill("SIGKILL");
			await exitPromise;
		},
		signalGroup: (signal) => {
			if (!opts.ownGroup || proc.pid === undefined) {
				throw new Error("signalGroup: start the runner with ownGroup");
			}
			process.kill(-proc.pid, signal);
		},
		awaitClose: () => closePromise,
		runsDir,
	};
}

// Each `startMeerkat` call without `runsDir` creates `meerkat-runs-<worker pid>-<random>`
// in the OS temp dir.
// Reap its recorded backends and remove the dir only if that PID is no longer alive;
// live owners, including concurrent runs, and dirs without a PID are left alone.
export async function reapOrphanedBackends(): Promise<void> {
	for (const name of readdirSync(tmpdir())) {
		const owner = name.match(OWNED_RUNS_DIR_RE);
		if (!owner || alive(Number(owner[1]))) continue;
		const dir = join(tmpdir(), name);
		await stopBackends(dir);
		rmSync(dir, { recursive: true, force: true });
	}
}

async function stopBackends(runsDir: string): Promise<void> {
	if (!existsSync(runsDir)) return;
	const pids = readdirSync(runsDir, { withFileTypes: true })
		.filter((entry) => entry.isDirectory())
		.map((entry) => join(runsDir, entry.name, "pid"))
		.filter((path) => existsSync(path))
		.map((path) => ({ pid: Number(readFileSync(path, "utf8").trim()), written: statSync(path).mtimeMs }))
		.filter(({ pid, written }) => startedBy(pid, written))
		.map(({ pid }) => pid);

	for (const pid of pids) {
		try {
			process.kill(pid, "SIGTERM");
		} catch {}
	}

	const deadline = Date.now() + 10_000;
	while (Date.now() < deadline && pids.some(alive)) {
		await new Promise((resolve) => setTimeout(resolve, 100));
	}
}

// A backend writes its pid file after it starts, so a process that started later
// only reuses the pid of a backend that has exited. `ps` truncates the elapsed time
// to whole seconds, hence the 1 s allowance; reading the clock before `ps` runs
// keeps the time `ps` takes from counting against it.
function startedBy(pid: number, pidWrittenMs: number): boolean {
	const now = Date.now();
	let etime: string;
	try {
		etime = execFileSync("ps", ["-o", "etime=", "-p", String(pid)], { encoding: "utf8" }).trim();
	} catch (e) {
		// `ps -p` exits 1 when no such process exists; any other failure would leave
		// backends running with nothing recording them, so it surfaces.
		if ((e as { status?: number }).status === 1) return false;
		throw e;
	}
	return now - elapsedSeconds(etime) * 1000 <= pidWrittenMs + 1000;
}

// Parses `ps -o etime=` output, `[[dd-]hh:]mm:ss`, into seconds.
export function elapsedSeconds(etime: string): number {
	const m = etime.match(/^(?:(?:(\d+)-)?(\d+):)?(\d+):(\d+)$/);
	if (!m) throw new Error(`unrecognised ps etime: ${JSON.stringify(etime)}`);
	const [, days = "0", hours = "0", minutes, seconds] = m;
	return ((Number(days) * 24 + Number(hours)) * 60 + Number(minutes)) * 60 + Number(seconds);
}

function alive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
}

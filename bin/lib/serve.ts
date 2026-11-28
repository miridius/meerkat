// The served half of the meerkat launchers, shared by `meerkat-shepherd`
// and `meerkat-beam`: each runs its BEAM in a loop here, in the run dir
// the caller in `attach.ts` started it with, and records how it ended
// there for that caller.

import { randomBytes } from "node:crypto";
import { existsSync, readFileSync, renameSync, rmSync, writeFileSync, writeSync } from "node:fs";
import { constants } from "node:os";
import { reviewHash, reviewRoot } from "./attach.ts";

type Env = Record<string, string | undefined>;

// A BEAM SIGTERMed while it boots, before `Meerkat.CLI.main/1` installs
// its own handler, meets OTP's, which exits 0. So the launchers' BEAM
// halts with 76 when `main/1` returns 0, and `decisionCode` reads only 76
// as approval, and a bare exit 0 as REJECT.
export const CLI_HALT = "System.halt(case Meerkat.CLI.main(System.argv()) do 0 -> 76; code -> code end)";

// The exit code a BEAM halts with to be restarted onto a new version.
export const RESTART_EXIT_CODE = 75;

const SIGNALS = ["SIGTERM", "SIGINT", "SIGHUP"] as const;

// The command that runs this launcher again: its compiled executable, or
// Bun running its entry script.
export const selfCommand = () => (Bun.main.startsWith("/$bunfs/") ? [process.execPath] : [process.execPath, Bun.main]);

export const say = (text: string) => {
	try {
		writeSync(2, text);
	} catch {}
};

export function decisionCode(code: number): number {
	if (code === 76) return 0;
	if (code === 0) {
		say(
			"meerkat: the review BEAM exited 0 before meerkat decided (a SIGTERM while it booted?) — defaulting to REJECT (commit aborted).\n",
		);
		return 143;
	}
	return code;
}

// The exit status a shell gives a process that Bun reports ended.
export function status(result: { exitCode: number | null; signalCode?: string | null }): number {
	if (result.exitCode !== null) return result.exitCode;
	return 128 + (constants.signals[result.signalCode as keyof typeof constants.signals] ?? 0);
}

// Whether `args` asks for answers read from stdin.
export const wantsAnswers = (args: string[]) => args.some((arg) => arg === "--answers" || arg === "--answers=true");

// `--answers` reads the answers from stdin, so it fails at once without
// any to read.
export function requireAnswersInput() {
	if (process.stdin.isTTY) {
		say(
			"meerkat: --answers reads the answers as JSON on stdin; pipe them in, e.g. meerkat --answers < answers.json\n",
		);
		process.exit(64);
	}
}

// The running BEAM, which a TERM, INT or HUP to the launcher SIGKILLs:
// otherwise a killed launcher orphans a BEAM that sits on its port
// forever.
let beam: Bun.Subprocess | null = null;

// SIGKILL, not SIGTERM: a TERM'd launcher means the review is being
// abandoned, and graceful BEAM shutdown is all downside here — Bandit
// drains the still-connected LiveView socket (tens of seconds) and the
// logger's shutdown writes race whoever deletes the work dir next. State
// worth keeping is already on disk; persistence saves on every change.
// Reap, so the port is provably free before the launcher exits.
async function onSignal() {
	const running = beam;
	if (running !== null) {
		running.kill("SIGKILL");
		await running.exited;
	}
	process.exit(143);
}

export function trapSignals() {
	for (const signal of SIGNALS) process.on(signal, () => void onSignal());
}

// Runs `command` as the BEAM and returns its exit status, with stdin as
// given: a shepherd's BEAM gets none.
export async function runBeam(command: string[], stdin: "inherit" | "ignore" = "ignore"): Promise<number> {
	const proc = Bun.spawn(command, { stdio: [stdin, "inherit", "inherit"], env: process.env });
	beam = proc;
	await proc.exited;
	beam = null;
	return status(proc);
}

// Runs the BEAM command given once, with the caller's stdin, and exits
// with its decision.
export async function runOnce(command: string[]): Promise<never> {
	trapSignals();
	process.exit(decisionCode(await runBeam(command, "inherit")));
}

// Writes `text` to `path` atomically.
const writeAtomically = (path: string, text: string) => {
	try {
		writeFileSync(`${path}.tmp`, text);
		renameSync(`${path}.tmp`, path);
	} catch {}
};

// A shepherd calls this before each BEAM it starts. It rewrites a missing
// `token` or `pid`, so losing one cannot leave callers unable to
// reattach, or taking a live backend for dead.
export function restoreRunFiles(dir: string, token: string) {
	if (!existsSync(`${dir}/token`)) writeAtomically(`${dir}/token`, `${token}\n`);
	if (!existsSync(`${dir}/pid`)) writeAtomically(`${dir}/pid`, `${process.pid}\n`);
}

// The port the first BEAM prefers. Explicit --port and --port=N
// (including --port 0) pass through unchanged and leave none preferred.
// Without an explicit port, prefer MEERKAT_PORT (useful for
// tests/debugging) or the review's stable port, int(sha256(root:args)[:8])
// % 20000 + 40000, with root from `reviewRoot`. This keeps a fresh
// invocation of the same review, with the same args in the same work
// tree, from any of its directories, on the same port so its browser tab
// needs no re-navigation. The 40000-59999 range is above privileged
// ports; its portion below 49152 is outside macOS's default ephemeral
// range, making OS-allocation collisions rare. If the preferred port is
// taken, the CLI warns and uses an OS-assigned port.
export function preferredPort(args: string[], env: Env, root: () => string): string | undefined {
	if (args.some((arg) => arg === "--port" || arg.startsWith("--port="))) return undefined;
	if (env.MEERKAT_PORT) return env.MEERKAT_PORT;
	return String((Number.parseInt(reviewHash(root(), args, 8), 16) % 20000) + 40000);
}

// The served half's loop: runs `beamCommand()` until its BEAM exits with
// anything but a restart, after `beforeEach` resolves for each, and exits
// with the decision. `retry`, given every BEAM's exit code, says whether
// to run another BEAM after one exits with a code other than 75.
export async function serve(opts: {
	args: string[];
	beforeEach: () => void;
	beamCommand: () => string[];
	restarting: string;
	retry?: (code: number) => boolean;
}): Promise<never> {
	const dir = process.env.MEERKAT_SERVE_DIR as string;
	const token = process.env.MEERKAT_SERVE_TOKEN ?? "";
	const pwd = process.env.MEERKAT_PWD ?? process.cwd();

	const port = preferredPort(opts.args, process.env, () => reviewRoot(pwd));
	if (port === undefined) delete process.env.MEERKAT_PREFERRED_PORT;
	else process.env.MEERKAT_PREFERRED_PORT = port;

	// Set the secret once before the respawn loop, preserving any inherited
	// value. Every BEAM can then verify the tab's existing LiveView session
	// token, so a restart reconnects in place instead of forcing a full
	// page reload.
	if (!process.env.SECRET_KEY_BASE) process.env.SECRET_KEY_BASE = randomBytes(48).toString("base64");

	// Browser-open marker: a file in the run dir the BEAM stamps the FIRST
	// time it successfully calls `open` on the review URL. A respawned BEAM
	// sees the marker and skips the open, so the user's existing tab keeps
	// its reconnect instead of getting a duplicate. `open URL` on macOS
	// doesn't reliably focus an existing tab when the tab is in another
	// Chrome workspace / profile. Not $TMPDIR, which macOS empties of files
	// three days old. The BEAM treats "empty" as "browser not yet opened";
	// after a successful open it writes "1".
	const marker = `${dir}/opened`;
	writeFileSync(marker, "");
	process.env.MEERKAT_OPEN_MARKER = marker;
	// The caller is not this shepherd's parent, so it reads the exit code
	// from the serve dir.
	process.on("exit", (code) => {
		rmSync(marker, { force: true });
		writeAtomically(`${dir}/exit`, `${code}\n`);
	});

	trapSignals();

	while (true) {
		opts.beforeEach();
		restoreRunFiles(dir, token);

		const code = decisionCode(await runBeam(opts.beamCommand()));
		// The port file records "<port> <pid>" for the port this BEAM bound.
		// Carry it forward after every exit, including runs using explicit
		// --port 0, so the next BEAM tries it first and the open browser tab
		// can reconnect.
		let portFile: string | null = null;
		try {
			portFile = readFileSync(`${dir}/port`, "utf8");
		} catch {}
		if (portFile !== null) {
			const bound = portFile.trim().split(/\s+/)[0];
			if (bound) process.env.MEERKAT_PREFERRED_PORT = bound;
			// Remove the exited BEAM's port so callers can't reattach to it
			// while the next BEAM is starting.
			rmSync(`${dir}/port`, { force: true });
		}

		const retry = opts.retry?.(code) ?? false;
		if (code === RESTART_EXIT_CODE) {
			say(`${opts.restarting}\n`);
			continue;
		}
		if (retry) continue;
		process.exit(code);
	}
}

// The caller half of the meerkat launchers, run by `meerkat-shepherd` and
// `meerkat-beam`. `attach` starts the review backend detached, or finds
// the one an earlier invocation of the same review left running, relays
// its stderr, and exits with its decision. The backend sits outside the
// caller's process tree, so killing the caller leaves the review running
// for the next invocation to reattach to.
//
// Each run has its own <runs>/<key>.<uuid> directory; <runs>/<key> is a
// symlink naming the current run by its relative sibling name,
// <key>.<uuid>. An attached caller keeps its own run dir, so a rerun
// cannot replace the exit status it reads. A real dir at <runs>/<key>
// belongs to an older meerkat; callers still attach to it because an
// orphaned review lives until reattached and can outlast an upgrade.
//
// A backend's run dir holds `pid` (its shepherd), `caller` (the pid of
// the caller waiting on it: a takeover overwrites it, and restores it if
// refused, or if stopped or its server exits before it hears from the
// server), `token`, `log` (its stderr), `port` ("<port> <BEAM pid>"
// while a BEAM serves), `served` (once a BEAM has announced the review),
// `opened` (the browser-open marker), `index` (a held temporary index,
// if any) and, once it has exited, `exit`. The attach stream's frames
// are documented in `MeerkatWeb.AttachController`.

import { spawn, spawnSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import {
	closeSync,
	existsSync,
	lstatSync,
	mkdirSync,
	openSync,
	readdirSync,
	readFileSync,
	readlinkSync,
	readSync,
	renameSync,
	rmSync,
	statSync,
	symlinkSync,
	writeFileSync,
	writeSync,
} from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";

type Env = Record<string, string | undefined>;

// The signals that stop a launcher.
export const SIGNALS = ["SIGTERM", "SIGINT", "SIGHUP"] as const;

export const say = (text: string) => {
	try {
		writeSync(2, text);
	} catch {}
};

// Writes `text` to `path` atomically, through a temporary name private to
// this process, as the caller and the shepherd both write some run files.
export const writeAtomically = (path: string, text: string) => {
	const tmp = `${path}.tmp.${process.pid}`;
	try {
		writeFileSync(tmp, text);
		renameSync(tmp, path);
	} catch {}
};

// What a run of ps gives back: its stdout, or `killed` when a signal
// ended it, as one sent to this invocation's whole process group.
export type PsResult = { out: string; killed: boolean };

// The answer to a request to the backend. `status` is the HTTP status, or
// 0 when the request got none; `timedOut` says a deadline ended it.
export type Reply = { status: number; body: string; timedOut: boolean };

// What a caller does to the world outside its run dir, so tests can stand
// in for each.
export type Deps = {
	ps: (args: string[]) => PsResult;
	// Throws as `process.kill` does.
	kill: (pid: number, signal: NodeJS.Signals | 0) => void;
	now: () => number;
	sleep: (ms: number) => Promise<void>;
	request: (method: string, url: string, token: string, timeoutMs?: number) => Promise<Reply>;
	// The attach stream: calls `line` with each complete line it reads,
	// and resolves with the HTTP status once it ends, or 0 when it got
	// none. Calls `tick` after each 0.2 s in which nothing arrives.
	stream: (
		url: string,
		token: string,
		signal: AbortSignal,
		line: (line: string) => void,
		tick: () => void,
	) => Promise<number>;
	startServer: (command: string[], dir: string, env: Env) => void;
	stderr: (text: string) => void;
	exit: (code: number) => never;
};

// The root of the work tree holding `pwd`, or outside one `pwd` itself:
// what the run dir and the preferred port are keyed on, as `Meerkat.CLI`
// keys the review, so a rerun of the same review from any directory of
// the tree finds both. The variables that would relocate the repo are
// dropped, as the CLI drops them.
export function reviewRoot(pwd: string, env: Env = process.env): string {
	const gitEnv = { ...env };
	for (const name of [
		"GIT_DIR",
		"GIT_WORK_TREE",
		"GIT_COMMON_DIR",
		"GIT_OBJECT_DIRECTORY",
		"GIT_ALTERNATE_OBJECT_DIRECTORIES",
		"GIT_NAMESPACE",
	])
		delete gitEnv[name];
	const result = spawnSync("git", ["-C", pwd, "rev-parse", "--show-cdup"], {
		env: gitEnv as NodeJS.ProcessEnv,
		encoding: "utf8",
		stdio: ["ignore", "pipe", "ignore"],
	});
	const cdup = result.status === 0 ? result.stdout.replace(/\n+$/, "") : "";
	if (cdup === "") return pwd;
	const top = resolve(pwd, cdup);
	return existsSync(top) ? top : pwd;
}

// The first `length` hex digits of the SHA-256 of a review's root and
// arguments, as the run dir and the preferred port are keyed.
export const reviewHash = (root: string, args: string[], length: number) =>
	createHash("sha256").update(`${root}:${args.join(" ")}`).digest("hex").slice(0, length);

// The runs dir. Not $TMPDIR: macOS deletes its files once they are three
// days old, and a review can wait longer than that.
export const runsDir = (env: Env, home: string) =>
	env.MEERKAT_RUNS_DIR || join(env.XDG_STATE_HOME || join(home, ".local/state"), "meerkat/runs");

const readOr = (path: string): string | null => {
	try {
		return readFileSync(path, "utf8");
	} catch {
		return null;
	}
};

const readlinkOr = (path: string): string | null => {
	try {
		return readlinkSync(path);
	} catch {
		return null;
	}
};

const isSymlink = (path: string) => {
	try {
		return lstatSync(path).isSymbolicLink();
	} catch {
		return false;
	}
};

const isDir = (path: string) => {
	try {
		return statSync(path).isDirectory();
	} catch {
		return false;
	}
};

const isFile = (path: string) => {
	try {
		return statSync(path).isFile();
	} catch {
		return false;
	}
};

// The first line's whitespace-separated fields of a file, or null when it
// cannot be read.
const fields = (path: string): string[] | null => {
	const text = readOr(path);
	return text === null ? null : (text.split("\n")[0] ?? "").trim().split(/\s+/);
};

export class Caller {
	readonly link: string;
	readonly run: string;
	// The run dir the caller works on, or "" before it finds one.
	dir = "";
	// Whether this caller took the run in `dir`.
	owned = false;
	// Whether this caller started its run or has heard from its server.
	held = false;
	prevCaller = "";
	// While owned, null or open on `dir`/log.
	logFd: number | null = null;
	quiet = false;
	// The run dir whose pid `pidWait` is the deadline for.
	pidWaitDir = "";
	pidWait = 0;
	ancestors: number[] = [];
	port = "";
	token = "";
	// Set once a signal stops the caller: every wait after it never ends,
	// so nothing but the stop runs.
	stopping = false;
	attachAbort: AbortController | null = null;

	constructor(
		readonly runs: string,
		readonly key: string,
		readonly deps: Deps,
		readonly pid = process.pid,
		run = randomUUID(),
	) {
		this.link = join(runs, key);
		this.run = run;
	}

	stderr(text: string) {
		this.deps.stderr(text);
	}

	exit(code: number): never {
		return this.deps.exit(code);
	}

	// Pause between polls. A stopping caller never wakes.
	async nap() {
		await this.deps.sleep(200);
		await this.halt();
	}

	halt(): Promise<void> {
		return this.stopping ? new Promise(() => {}) : Promise.resolve();
	}

	async attach(command: string[], env: Env, signals = true): Promise<never> {
		mkdirSync(this.runs, { recursive: true });
		this.ancestors = this.ancestorChain();
		if (signals)
			for (const signal of SIGNALS)
				process.on(signal, () => void this.stopped(signal));
		this.reapFinished();

		while (true) {
			if (!this.owned && !this.findServer()) continue;

			// With no run, `dir` is "", and `exit` would name a file in the
			// working directory.
			if (this.dir !== "" && isFile(join(this.dir, "exit"))) {
				if (this.owned && !this.held) {
					// A reattach whose server exited before it heard from it: that
					// exit code was not this invocation's. Hand the run back to the
					// caller it replaced, or remove it if none, and start afresh, as
					// a new invocation would.
					this.restoreCaller();
					if (readOr(join(this.dir, "caller"))?.trim() === String(this.pid)) this.must(() => this.removeRun());
					this.owned = false;
					continue;
				}
				if (this.owned) {
					this.relayLog();
					const code = Number.parseInt(readOr(join(this.dir, "exit")) ?? "", 10);
					this.removeDecidedRun();
					this.exit(Number.isNaN(code) ? 2 : code);
				}
				// Its exit code is for the caller attached to it, which removes it.
				if (!this.callerAlive(this.dir)) {
					// No live caller is recorded: remove its finished run now.
					this.must(() => this.removeRun());
				} else if (this.dir !== this.link || this.exitStale(this.dir)) {
					this.must(() => this.retire(this.dir));
				} else {
					await this.nap();
				}
				continue;
			}

			if (!isDir(this.dir)) {
				if (this.owned && !this.held) {
					// A reattach that never heard from its server, whose run another
					// invocation has since removed (the caller before it, done with
					// it, or one that found the server dead): start afresh, as a new
					// invocation would.
					this.owned = false;
					continue;
				}
				if (this.owned) {
					// Another invocation removed our run dir, after its server died
					// or over a minute after it finished (for example, while the
					// laptop slept). We cannot read our own run's exit code, so fail
					// closed instead of starting a new server.
					this.stderr(`meerkat: ${this.dir} was removed — defaulting to REJECT (commit aborted).\n`);
					this.exit(2);
				}
				if (!this.startServer(command, env)) {
					// Another caller started one first.
					if (isSymlink(this.link) || existsSync(this.link)) continue;
					// Otherwise every retry fails the same way, without pause.
					this.stderr(`meerkat: could not create ${this.dir} — defaulting to REJECT (commit aborted).\n`);
					this.exit(2);
				}
			} else if (!this.serverAlive()) {
				this.buryServer();
				continue;
			}

			// A reattaching caller skips the log so far: the attach stream
			// sends it the banner.
			if (!this.owned) {
				this.owned = true;
				this.held = false;
				if (this.openLog()) this.readLog();
				this.prevCaller = readOr(join(this.dir, "caller"))?.trim() ?? "";
				this.writeCaller();
			}
			this.relayLog();

			if (isFile(join(this.dir, "port"))) {
				await this.attachStream(env);
			} else {
				await this.nap();
			}
		}
	}

	// The pids above the caller, from its parent up to the nearest git,
	// which waits on a hook, so an exit above it, such as the app that ran
	// git commit restarting, leaves git commit waiting on the decision.
	// With no git above it, stop at the caller's process group leader, or
	// at its parent when the caller leads its group, or else just below
	// pid 1. Use ps, not kill 0, which takes live root-owned processes such
	// as a terminal's login process for dead.
	ancestorChain(): number[] {
		const [ppid, pgid] = this.deps
			.ps(["-o", "ppid=,pgid=", "-p", String(this.pid)])
			.out.trim()
			.split(/\s+/)
			.map(Number);
		const chain: number[] = [];
		let upto: number[] | null = null;
		let pid = ppid;
		while (pid !== undefined && pid > 1) {
			chain.push(pid);
			if (upto === null && (pid === pgid || pgid === this.pid)) upto = [...chain];
			const [next, ...comm] = this.deps
				.ps(["-o", "ppid=,comm=", "-p", String(pid)])
				.out.trim()
				.split(/\s+/);
			if (basename(comm.join(" ")) === "git") {
				upto = [...chain];
				break;
			}
			pid = next === undefined || next === "" ? Number.NaN : Number(next);
		}
		return upto ?? chain;
	}

	// A killed git commit can leave its hook (and this caller) running and
	// attached. It would then take delivery of the decision where nobody
	// can read it, so on receiving it, exit if the chain above the caller
	// has changed and leave the decision held for the next invocation. A
	// process that exits reparents the one below it, so the chain changes
	// even once its pid is reused. Checked only then: reviews wait hours,
	// and a killed commit is rare. Until the decision or a rerun's
	// takeover, the orphan stays attached, so the deadline keeps running
	// for it. Where ps cannot tell (a sandbox denies it), assume the
	// ancestors live: taking them for dead would hold every decision.
	exitIfOrphaned() {
		if (this.ancestors.length === 0 || !this.psWorks()) return;
		if (this.ancestorChain().join(" ") !== this.ancestors.join(" ")) {
			this.stillOpen("the process that ran meerkat exited");
			this.exit(1);
		}
	}

	// Whether ps can see processes at all: it lists this caller.
	psWorks() {
		return this.deps.ps(["-o", "pid=", "-p", String(this.pid)]).out.trim() !== "";
	}

	// A caller stopped before the decision says how the review stands, so
	// whoever ran it learns whether to rerun instead of reading only an
	// exit status. It then dies of the signal, as it would have untrapped.
	async stopped(signal: NodeJS.Signals) {
		if (this.stopping) return;
		this.stopping = true;
		this.attachAbort?.abort();
		await this.leave(`stopped waiting (${signal})`);
		process.removeAllListeners(signal);
		process.kill(process.pid, signal);
	}

	// Detach from the backend, which judges the review at once, and say to
	// rerun, with the review's URL when the backend answers that it is
	// still open. Only a caller that took the run acts on it. A rerun that
	// has not yet heard from the backend only hands the run back to the
	// caller it replaced, which may still wait on it: a leave would have
	// the backend judge the review while that caller is between attaches.
	// Any other caller stops a backend that has not announced the review or
	// does not answer within 2 s. One that answers with an error, or is
	// between BEAMs, is left running.
	async leave(why: string) {
		if (this.owned && !this.held) {
			this.restoreCaller();
		} else if (this.owned) {
			let reply: Reply | null = null;
			const port = fields(join(this.dir, "port"));
			if (port !== null) {
				this.port = port[0] ?? "";
				this.token = readOr(join(this.dir, "token"))?.trim() ?? "";
				reply = await this.deps.request("POST", this.url(`attach/leave?run=${this.run}`), this.token, 2000);
			}
			const ok = reply !== null && reply.status >= 200 && reply.status < 300;
			const standing = ok ? reply?.body : "";
			if (standing === "open") {
				this.stillOpen(why);
				return;
			}
			if (standing !== "ended" && (!existsSync(join(this.dir, "served")) || reply?.timedOut)) {
				const pid = Number.parseInt(readOr(join(this.dir, "pid")) ?? "", 10);
				if (isFile(join(this.dir, "pid")) && this.serverAlive()) {
					try {
						this.deps.kill(pid, "SIGTERM");
					} catch {}
				}
			}
		}
		this.stderr(`meerkat: ${why} before the review completed. Run the same command again.\n`);
	}

	stillOpen(why: string) {
		// The run dir, port file included, may be deleted by the time the
		// decision arrives.
		const port = fields(join(this.dir, "port"));
		const at = port === null ? "" : ` at http://127.0.0.1:${port[0]}/`;
		this.stderr(
			`meerkat: ${why} before the review completed. The review is still open${at}; run the same command again to wait for its outcome.\n`,
		);
	}

	// Open the run's log, closing the last run's, and fail when it has none
	// yet. The open file keeps the caller's place in the log between
	// relays.
	openLog(): boolean {
		if (this.logFd !== null) closeSync(this.logFd);
		this.logFd = null;
		try {
			this.logFd = openSync(join(this.dir, "log"), "r");
			return true;
		} catch {
			return false;
		}
	}

	// The log written since the last read, a partial last line included.
	readLog(): string {
		if (this.logFd === null) return "";
		const chunks: Buffer[] = [];
		const buffer = Buffer.alloc(65536);
		while (true) {
			let n = 0;
			try {
				n = readSync(this.logFd, buffer);
			} catch {
				break;
			}
			if (n <= 0) break;
			chunks.push(Buffer.from(buffer.subarray(0, n)));
		}
		return Buffer.concat(chunks).toString("utf8");
	}

	relayLog() {
		if (this.logFd === null && !this.openLog()) return;
		const text = this.readLog();
		if (text !== "") this.stderr(text);
	}

	// Set `dir` to the run dir the key currently names and succeed, or to
	// "" and succeed when it names none, so the loop starts one. Drop a
	// symlink whose target dir is gone and fail so the loop looks again. A
	// real dir is an older meerkat's run: still use it because an orphaned
	// review lives until reattached and can outlast an upgrade.
	findServer(): boolean {
		this.dir = "";
		if (isSymlink(this.link)) {
			const target = readlinkOr(this.link);
			if (target === null) return false;
			this.dir = join(dirname(this.link), target);
			if (target !== "" && isDir(this.dir)) return true;
			this.must(() => this.retire(this.dir));
			return false;
		}
		if (isDir(this.link)) this.dir = this.link;
		return true;
	}

	// Drop the key's symlink if it still names the given run dir; for an
	// old-layout real dir, delete the dir itself. Fail only when the runs
	// dir cannot be changed. Read first, so the usual case, a link already
	// repointed, is never touched. Then rename the link to a name private
	// to this invocation, so only one invocation drops it, and check it
	// again: if another invocation repointed it meanwhile, put it back
	// unless a newer link has already taken its place.
	retire(dir: string): boolean {
		if (dir === this.link) {
			rmSync(dir, { recursive: true, force: true });
			return true;
		}
		const name = basename(dir);
		const held = `${this.link}.retiring.${this.run}`;
		if (readlinkOr(this.link) !== name) return true;
		try {
			renameSync(this.link, held);
		} catch {
			return readlinkOr(this.link) !== name;
		}
		if (!isSymlink(held)) {
			// An older meerkat made a real dir there in between: give it back.
			try {
				renameSync(held, this.link);
			} catch {}
			return true;
		}
		const target = readlinkOr(held);
		if (target !== null && target !== "" && target !== name) {
			try {
				symlinkSync(target, this.link);
			} catch {}
		}
		rmSync(held, { force: true });
		return true;
	}

	// Remove the run in `dir`: the key's symlink if it still names it, and
	// the run dir itself.
	removeRun(): boolean {
		if (!this.retire(this.dir)) return false;
		try {
			rmSync(this.dir, { recursive: true, force: true });
		} catch {
			return false;
		}
		return !existsSync(this.dir);
	}

	// Remove the run whose decision the caller holds: failing to cannot
	// cost the decision.
	removeDecidedRun() {
		try {
			this.removeRun();
		} catch {}
	}

	// Make a change to the runs dir, failing closed if it cannot be made:
	// retrying it would spin, and going on with a run half removed would
	// misread it.
	must(change: () => boolean) {
		let done = false;
		try {
			done = change();
		} catch {}
		if (done) return;
		this.stderr(`meerkat: could not update ${dirname(this.link)} — defaulting to REJECT (commit aborted).\n`);
		this.exit(2);
	}

	// Write a pid, this caller's by default, to the run's `caller` file,
	// atomically: a reader seeing it empty would take the caller for dead.
	writeCaller(pid: string | number = this.pid) {
		writeAtomically(join(this.dir, "caller"), `${pid}\n`);
	}

	// A reattach the server refused, whose server exited before it heard
	// from it, or that is stopped before then, records again the caller it
	// would have replaced, which may still wait on the run. A caller
	// displaced by a later one does nothing: the file no longer names it.
	restoreCaller() {
		if (this.prevCaller === "" || readOr(join(this.dir, "caller"))?.trim() !== String(this.pid)) return;
		this.writeCaller(this.prevCaller);
	}

	// Once at invocation start, delete this key's finished run dirs whose
	// caller is not alive or whose exit file is over a minute old. The
	// minute limit covers callers ps cannot check, where it is denied or a
	// signal kills it, and a reused pid that passes the command check.
	reapFinished() {
		let names: string[] = [];
		try {
			names = readdirSync(this.runs);
		} catch {}
		const prefix = `${basename(this.link)}.`;
		for (const name of names.filter((n) => n.startsWith(prefix)).sort()) {
			const dir = join(this.runs, name);
			if (isSymlink(dir) || !isDir(dir) || !isFile(join(dir, "exit"))) continue;
			if (!this.callerAlive(dir) || this.exitStale(dir)) {
				this.must(() => {
					rmSync(dir, { recursive: true, force: true });
					return true;
				});
			}
		}
	}

	// True once the run dir's exit file is over a minute old. This gives
	// the attached caller time to read its exit code: it polls every 0.2 s,
	// so a minute is far beyond its normal delay.
	exitStale(dir: string): boolean {
		try {
			return Date.now() - statSync(join(dir, "exit")).mtimeMs > 60_000;
		} catch {
			return false;
		}
	}

	// True if `dir`/caller names a live process whose command contains
	// "meerkat". The command check stops a reused pid from passing for the
	// caller. Where ps cannot tell, assume the caller lives: its run is
	// then reaped once its exit file is stale, rather than taken from a
	// caller still reading it.
	callerAlive(dir: string): boolean {
		const pid = readOr(join(dir, "caller"))?.trim();
		if (pid === undefined || pid === "") return false;
		return this.mayRunMeerkat(pid);
	}

	// Whether ps shows `pid` running meerkat: a reused pid runs something
	// else. "unknown" when ps cannot tell because a signal killed it, as
	// one sent to this invocation's whole process group.
	runsMeerkat(pid: string): boolean | "unknown" {
		const result = this.deps.ps(["-p", pid, "-o", "command="]);
		if (result.killed) return "unknown";
		return /[Mm]eerkat/.test(result.out);
	}

	// Whether `pid` may run meerkat: ps shows it does, or cannot tell.
	mayRunMeerkat(pid: string): boolean {
		return !this.psWorks() || this.runsMeerkat(pid) !== false;
	}

	startServer(command: string[], env: Env): boolean {
		this.dir = `${this.link}.${randomUUID()}`;
		try {
			mkdirSync(this.dir);
		} catch {
			return false;
		}
		// Written before the link makes the run findable, so a reattach
		// finds them in place.
		const token = randomUUID();
		writeFileSync(join(this.dir, "token"), `${token}\n`);
		this.writeCaller();
		try {
			symlinkSync(basename(this.dir), this.link);
		} catch {
			rmSync(this.dir, { recursive: true, force: true });
			return false;
		}
		this.owned = true;
		this.held = true;
		// This closes the last run's log; with none here yet, the first
		// relay opens this one's from its start.
		this.openLog();
		this.deps.startServer(command, this.dir, {
			...env,
			MEERKAT_SERVE_DIR: this.dir,
			MEERKAT_SERVE_TOKEN: token,
			MEERKAT_RUN_ID: this.run,
		});
		return true;
	}

	serverAlive(): boolean {
		// The caller writes `pid` once the spawn returns.
		if (!isFile(join(this.dir, "pid"))) {
			// Wait up to 10 s by the clock, not by polls: under load each poll
			// takes longer than its sleep. Each run gets its own wait, and so
			// does a pid that goes missing after it was seen.
			if (this.pidWaitDir !== this.dir) {
				this.pidWaitDir = this.dir;
				this.pidWait = this.deps.now() + 10_000;
			}
			return this.deps.now() < this.pidWait;
		}
		this.pidWaitDir = "";
		// Another invocation can remove the run since the check above.
		const pid = Number.parseInt(readOr(join(this.dir, "pid")) ?? "", 10);
		if (Number.isNaN(pid)) return false;
		try {
			this.deps.kill(pid, 0);
		} catch {
			return false;
		}
		if (isFile(join(this.dir, "exit"))) return true;
		// The command check stops a reused pid passing for the backend.
		// Where ps cannot tell, the live pid is all there is to go on.
		return this.mayRunMeerkat(String(pid));
	}

	buryServer() {
		// It exited cleanly after the loop's exit check, or another
		// invocation removed its run since `serverAlive` found its pid file
		// (as while this caller was suspended); the next pass handles either
		// as the main loop does.
		if (isFile(join(this.dir, "exit")) || !isDir(this.dir)) return;
		const port = fields(join(this.dir, "port"));
		const beam = port?.[1];
		// A BEAM whose shepherd died still holds the review's port. It is
		// killed only if ps shows it running meerkat: a pid ps cannot
		// check, which may have been reused, is left running.
		if (beam !== undefined && beam !== "" && this.runsMeerkat(beam) === true) {
			try {
				this.deps.kill(Number(beam), "SIGKILL");
			} catch {}
		}
		// The removal can also land while the BEAM is checked.
		if (!isDir(this.dir)) return;
		if (this.owned) {
			this.relayLog();
			this.stderr("meerkat: the review backend died without a decision — defaulting to REJECT (commit aborted).\n");
			this.must(() => this.removeRun());
			this.exit(2);
		}
		this.must(() => this.removeRun());
	}

	async waitForExit() {
		for (let i = 0; i < 150; i++) {
			// A deleted run dir never gets its exit file.
			if (!isDir(this.dir) || isFile(join(this.dir, "exit"))) return;
			if (!this.serverAlive()) return;
			await this.nap();
		}
	}

	url(path: string) {
		return `http://127.0.0.1:${this.port}/api/${path}`;
	}

	async attachStream(env: Env) {
		// Cache these for every request, including the attach/delivered
		// acknowledgement sent after the decision: the run dir may have been
		// deleted by then, so rereading its files would fail and leave the
		// backend running.
		const port = fields(join(this.dir, "port"));
		const token = readOr(join(this.dir, "token"));
		if (port === null || token === null) {
			await this.nap();
			return;
		}
		this.port = port[0] ?? "";
		this.token = token.trim();
		// Send the index git named for this invocation: `git commit -a` and
		// `git commit <path>` commit from a temporary one, and a backend
		// that reviewed a different index is not reviewing this commit.
		const query = new URLSearchParams({ run: this.run, quiet: this.quiet ? "1" : "0", index: env.GIT_INDEX_FILE ?? "" });
		let code: number | null = null;
		const abort = new AbortController();
		this.attachAbort = abort;

		const status = await this.deps.stream(
			this.url(`attach?${query}`),
			this.token,
			abort.signal,
			(line) => {
				if (this.stopping || abort.signal.aborted) return;
				const banner = line.startsWith("o ") || line.startsWith("n ");
				// Relay server stderr since the last relay before banner frames,
				// preserving the warning-before-banner order.
				if (banner) this.relayLog();
				if (line.startsWith("o ")) this.stderr(`${line.slice(2)}\n`);
				else if (line.startsWith("n ")) this.stderr(line.slice(2));
				else if (line.startsWith("x ")) {
					code = Number.parseInt(line.slice(2), 10);
					this.held = true;
					// The outcome is printed: a signal now just ends the caller.
					for (const signal of SIGNALS) process.removeAllListeners(signal);
				} else if (line === "d") {
					// Keep for older backends that send bare d; an orphaned review
					// lives until reattached, so the backend can outlast an upgrade.
					abort.abort();
					this.stderr("meerkat: a later invocation of this review took it over — aborting.\n");
					this.exit(1);
				} else if (line.startsWith("d ")) {
					abort.abort();
					this.restoreCaller();
					this.stderr(`${line.slice(2)}\n`);
					this.exit(1);
				}
				// A reattach after a BEAM restart must not print the banner again.
				if (banner) {
					this.quiet = true;
					this.held = true;
				}
			},
			() => {
				if (!this.stopping) this.relayLog();
			},
		);
		this.attachAbort = null;
		await this.halt();

		if (code !== null) {
			this.exitIfOrphaned();
			await this.deps.request("POST", this.url(`attach/delivered?run=${this.run}`), this.token);
			await this.waitForExit();
			this.relayLog();
			this.removeDecidedRun();
			this.exit(Number.isNaN(code) ? 2 : code);
		}

		// 409 means the review changed, and 503 that another caller took
		// delivery or the review ended with nothing waiting on it; either
		// way, the backend is exiting and this caller starts a fresh one.
		// 502 means this rerun could not resolve its review target or named
		// an index that no longer exists; the error was printed from its o
		// frames, the backend keeps its review, and this caller exits 64,
		// the CLI's unresolved-target exit code.
		if (status === 409 || status === 503) {
			this.owned = false;
			await this.waitForExit();
			this.removeRun();
		} else if (status === 502) {
			this.restoreCaller();
			this.exit(64);
		} else {
			await this.nap();
		}
	}
}

// The deps of a real caller.
export const realDeps: Deps = {
	ps(args) {
		const result = spawnSync("ps", args, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
		return { out: result.stdout ?? "", killed: result.signal !== null };
	},
	kill: (pid, signal) => process.kill(pid, signal),
	now: () => performance.now(),
	sleep: (ms) => new Promise((done) => setTimeout(done, ms)),
	async request(method, url, token, timeoutMs) {
		try {
			const response = await fetch(url, {
				method,
				headers: { "x-meerkat-token": token },
				signal: timeoutMs === undefined ? undefined : AbortSignal.timeout(timeoutMs),
			});
			return { status: response.status, body: (await response.text()).trim(), timedOut: false };
		} catch (error) {
			return { status: 0, body: "", timedOut: (error as Error).name === "TimeoutError" };
		}
	},
	async stream(url, token, signal, line, tick) {
		let response: Response;
		try {
			response = await fetch(url, { headers: { "x-meerkat-token": token }, signal });
		} catch {
			return 0;
		}
		if (response.body === null) return response.status;
		const reader = response.body.getReader();
		const decoder = new TextDecoder();
		let pending = "";
		let read = reader.read();
		while (true) {
			let timer: ReturnType<typeof setTimeout> | undefined;
			const timeout = new Promise<"tick">((done) => {
				timer = setTimeout(() => done("tick"), 200);
			});
			let next: "tick" | ReadableStreamReadResult<Uint8Array>;
			try {
				next = await Promise.race([read, timeout]);
			} catch {
				// The connection broke, or the caller aborted it.
				break;
			} finally {
				clearTimeout(timer);
			}
			if (next === "tick") {
				tick();
				continue;
			}
			if (next.done) break;
			pending += decoder.decode(next.value, { stream: true });
			let end = pending.indexOf("\n");
			while (end >= 0) {
				line(pending.slice(0, end));
				pending = pending.slice(end + 1);
				end = pending.indexOf("\n");
			}
			read = reader.read();
		}
		return response.status;
	},
	startServer(command, dir, env) {
		// A detached spawn takes the backend out of the caller's process
		// group and session, so a signal to the caller's whole tree (the app
		// that ran it restarting) leaves the review running.
		const log = openSync(join(dir, "log"), "a");
		const child = spawn(command[0] ?? "", command.slice(1), {
			detached: true,
			env: env as NodeJS.ProcessEnv,
			stdio: ["ignore", log, log],
		});
		closeSync(log);
		child.on("error", (error) => {
			try {
				writeFileSync(join(dir, "log"), `meerkat: exec ${command[0]}: ${error.message}\n`, { flag: "a" });
			} catch {}
		});
		child.unref();
		if (child.pid !== undefined) writeAtomically(join(dir, "pid"), `${child.pid}\n`);
	},
	stderr: say,
	exit: (code) => process.exit(code),
};

// Runs the caller for a launcher whose served half `command` runs, keyed
// on the review in `pwd` and `args`; never returns.
export function attach(command: string[], args: string[], pwd: string, env: Env = process.env): Promise<never> {
	const caller = new Caller(runsDir(env, homedir()), reviewHash(reviewRoot(pwd, env), args, 16), realDeps);
	return caller.attach([...command, ...args], env);
}

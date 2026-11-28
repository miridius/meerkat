import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Caller, type Deps, type PsResult, type Reply, realDeps } from "./attach.ts";

class Exit extends Error {
	constructor(readonly code: number) {
		super(`exit ${code}`);
	}
}

const dirs: string[] = [];
afterEach(() => {
	for (const dir of dirs.splice(0)) {
		chmodSync(dir, 0o755);
		rmSync(dir, { recursive: true, force: true });
	}
});

const tmp = () => {
	const dir = mkdtempSync(join(tmpdir(), "meerkat-attach-"));
	dirs.push(dir);
	return dir;
};

// A process table ps reads: pid -> [ppid, pgid, command].
type Table = Record<number, [number, number, string]>;

// ps over `table`, as `ps -o <fields> -p <pid>` prints it.
const psOf =
	(table: Table) =>
	(args: string[]): PsResult => {
		const pid = Number(args[args.indexOf("-p") + 1]);
		const fields = args[args.indexOf("-o") + 1] ?? "";
		const row = table[pid];
		if (row === undefined) return { out: "", killed: false };
		const [ppid, pgid, command] = row;
		const values: Record<string, string> = {
			"pid=": String(pid),
			"ppid=,pgid=": `${ppid} ${pgid}`,
			"ppid=,comm=": `${ppid} ${command.split(" ")[0]}`,
			"command=": command,
		};
		return { out: `${values[fields] ?? ""}\n`, killed: false };
	};

// The caller, pid 100, runs under a hook (99) under git (98), which leads
// its group under a shell (97).
const table: Table = {
	100: [99, 98, "bun meerkat-shepherd"],
	99: [98, 98, "sh .git/hooks/commit-msg"],
	98: [97, 98, "/usr/bin/git commit"],
	97: [1, 97, "-zsh"],
};

type Seen = { stderr: string; kills: string[]; requests: string[] };

function caller(runs: string, overrides: Partial<Deps> = {}, seen: Seen = { stderr: "", kills: [], requests: [] }) {
	let clock = 0;
	const deps: Deps = {
		ps: psOf(table),
		kill: (pid, signal) => {
			if (signal !== 0) seen.kills.push(`${signal} ${pid}`);
		},
		now: () => clock,
		sleep: async (ms) => {
			clock += ms;
		},
		request: async (method, url) => {
			seen.requests.push(`${method} ${url}`);
			return { status: 200, body: "", timedOut: false };
		},
		stream: async () => 0,
		startServer: () => {},
		stderr: (text) => {
			seen.stderr += text;
		},
		exit: (code) => {
			throw new Exit(code);
		},
		...overrides,
	};
	const c = new Caller(runs, "key", deps, 100, "run");
	return { c, seen, tick: (ms: number) => (clock += ms) };
}

async function exitCode(run: Promise<unknown> | (() => unknown)): Promise<number | null> {
	try {
		await (typeof run === "function" ? run() : run);
		return null;
	} catch (error) {
		if (error instanceof Exit) return error.code;
		throw error;
	}
}

// A run dir whose BEAM serves port 4242 and has decided with exit code 1.
function decided(runs: string) {
	const dir = join(runs, "key.1");
	mkdirSync(dir);
	writeFileSync(join(dir, "port"), "4242 1\n");
	writeFileSync(join(dir, "token"), "token\n");
	writeFileSync(join(dir, "exit"), "1\n");
	return dir;
}

// An attach stream that sends an outcome with exit code 1.
const outcome: Deps["stream"] = async (_url, _token, _signal, line) => {
	for (const l of ["k", "o outcome", "x 1"]) line(l);
	return 200;
};

describe("a caller given the decision", () => {
	const orphaned =
		"meerkat: the process that ran meerkat exited before the review completed. The review is still open at http://127.0.0.1:4242/; run the same command again to wait for its outcome.\n";

	test("takes delivery while its ancestors live", async () => {
		const runs = tmp();
		const { c, seen } = caller(runs, { stream: outcome });
		c.ancestors = c.ancestorChain();
		expect(c.ancestors).toEqual([99, 98]);
		c.dir = decided(runs);
		expect(await exitCode(c.attachStream({}))).toBe(1);
		expect(seen.stderr).toBe("outcome\n");
		expect(seen.requests).toEqual(["POST http://127.0.0.1:4242/api/attach/delivered?run=run"]);
		expect(existsSync(c.dir)).toBe(false);
	});

	// A pid a live process has since taken is a changed chain too.
	test("leaves it held once an ancestor's pid is reused", async () => {
		const runs = tmp();
		const { c, seen } = caller(runs, { stream: outcome });
		c.ancestors = [55, ...c.ancestorChain()];
		c.dir = decided(runs);
		expect(await exitCode(c.attachStream({}))).toBe(1);
		expect(seen.stderr).toBe(`outcome\n${orphaned}`);
		expect(seen.requests).toEqual([]);
	});

	// Where ps is denied, it cannot tell, so it takes delivery.
	test("takes delivery where ps cannot see processes", async () => {
		const runs = tmp();
		const { c, seen } = caller(runs, { stream: outcome, ps: () => ({ out: "", killed: false }) });
		c.ancestors = [55];
		c.dir = decided(runs);
		expect(await exitCode(c.attachStream({}))).toBe(1);
		expect(seen.stderr).toBe("outcome\n");
		expect(seen.requests).toHaveLength(1);
	});

	// The run dir can be deleted while the review is open. The caller
	// acknowledges the decision with what it read when it attached, so the
	// backend still ends, and does not wait for an exit file the deleted dir
	// never gets.
	test("whose run dir is deleted first takes delivery and exits at once", async () => {
		const runs = tmp();
		let naps = 0;
		const { c, seen } = caller(runs, {
			stream: async (url, token, signal, line) => {
				rmSync(c.dir, { recursive: true });
				return outcome(url, token, signal, line, () => {});
			},
			sleep: async () => {
				naps++;
			},
			request: async (method, url, token) => {
				seen.requests.push(`${method} ${url} ${token}`);
				return { status: 200, body: "", timedOut: false };
			},
		});
		c.dir = decided(runs);
		expect(await exitCode(c.attachStream({}))).toBe(1);
		expect(seen.requests).toEqual(["POST http://127.0.0.1:4242/api/attach/delivered?run=run token"]);
		expect(naps).toBe(0);
	});
});

describe("the ancestor chain", () => {
	test("stops at the nearest git", () => {
		const { c } = caller(tmp());
		expect(c.ancestorChain()).toEqual([99, 98]);
	});

	test("without a git, stops at the caller's group leader", () => {
		const { c } = caller(tmp(), {
			ps: psOf({ 100: [99, 98, "bun"], 99: [98, 98, "sh"], 98: [97, 98, "bash"], 97: [1, 97, "zsh"] }),
		});
		expect(c.ancestorChain()).toEqual([99, 98]);
	});

	test("for a caller leading its group, stops at its parent", () => {
		const { c } = caller(tmp(), { ps: psOf({ 100: [99, 100, "bun"], 99: [98, 98, "sh"], 98: [1, 98, "bash"] }) });
		expect(c.ancestorChain()).toEqual([99]);
	});

	test("with neither, runs up to just below pid 1", () => {
		const { c } = caller(tmp(), { ps: psOf({ 100: [99, 5, "bun"], 99: [98, 98, "sh"], 98: [1, 7, "bash"] }) });
		expect(c.ancestorChain()).toEqual([99, 98]);
	});
});

// A caller relays its backend's log as it grows: from the start for a
// run it started, even one with no log yet, and from the end on reattach.
test("a caller relays each part of its backend's log once", () => {
	const runs = tmp();
	const { c, seen } = caller(runs);
	c.dir = join(runs, "started");
	mkdirSync(c.dir);
	expect(c.openLog()).toBe(false);
	c.relayLog();
	writeFileSync(join(c.dir, "log"), " a\\b\npart");
	c.relayLog();
	writeFileSync(join(c.dir, "log"), "ial\n", { flag: "a" });
	c.relayLog();
	c.relayLog();
	c.dir = join(runs, "reattached");
	mkdirSync(c.dir);
	writeFileSync(join(c.dir, "log"), "seen\n");
	expect(c.openLog()).toBe(true);
	c.readLog();
	writeFileSync(join(c.dir, "log"), "b\n", { flag: "a" });
	c.relayLog();
	writeFileSync(join(runs, "started/log"), "a\npartial\n", { flag: "a" });
	c.relayLog();
	expect(seen.stderr).toBe(" a\\b\npartial\nb\n");
});

// After a 409 or 503 the caller starts a fresh backend, whose stderr it
// relays rather than the last run's log.
test("a caller relays the log of the backend it starts, not the last run's", async () => {
	const runs = tmp();
	const self = join(runs, "self");
	writeFileSync(self, "#!/bin/sh\necho new >&2\n");
	chmodSync(self, 0o755);
	const { c, seen } = caller(runs, { startServer: realDeps.startServer });
	c.dir = join(runs, "old");
	mkdirSync(c.dir);
	writeFileSync(join(c.dir, "log"), "old\n");
	c.openLog();
	c.readLog();
	expect(c.startServer([self], {})).toBe(true);
	const log = join(c.dir, "log");
	while (!existsSync(log) || readFileSync(log, "utf8") === "") await Bun.sleep(20);
	c.relayLog();
	expect(seen.stderr).toBe("new\n");
	expect(readFileSync(join(c.dir, "pid"), "utf8")).toMatch(/^\d+\n$/);
});

describe("a caller stopped before the decision", () => {
	// A run this caller started, whose BEAM `served` the review and whose
	// port file names `port`, if any.
	function started(runs: string, opts: { served: boolean; port: boolean }) {
		const dir = join(runs, "key.1");
		mkdirSync(dir);
		writeFileSync(join(dir, "token"), "token\n");
		writeFileSync(join(dir, "pid"), `${process.pid}\n`);
		if (opts.served) writeFileSync(join(dir, "served"), "");
		if (opts.port) writeFileSync(join(dir, "port"), "4242 1\n");
		return dir;
	}

	const rerun = "meerkat: stopped waiting (SIGTERM) before the review completed. Run the same command again.\n";
	const open =
		"meerkat: stopped waiting (SIGTERM) before the review completed. The review is still open at http://127.0.0.1:4242/; run the same command again to wait for its outcome.\n";

	// Whether the caller stops the backend, and what it says, for a backend
	// that has not announced the review, is between BEAMs, does not answer
	// within 2 s, answers with an error, or answers how the review stands.
	for (const [backend, served, port, reply, stops, said] of [
		["starts", false, false, null, true, rerun],
		["is between BEAMs", true, false, null, false, rerun],
		["does not answer within 2 s", true, true, { status: 0, body: "", timedOut: true }, true, rerun],
		["answers with an error", true, true, { status: 500, body: "", timedOut: false }, false, rerun],
		["cannot be reached", true, true, { status: 0, body: "", timedOut: false }, false, rerun],
		["answers that the review ended", true, true, { status: 200, body: "ended", timedOut: false }, false, rerun],
		["answers that the review is open", true, true, { status: 200, body: "open", timedOut: false }, false, open],
	] as [string, boolean, boolean, Reply | null, boolean, string][]) {
		test(`while its backend ${backend} ${stops ? "stops" : "leaves"} it and says how the review stands`, async () => {
			const runs = tmp();
			const timeouts: (number | undefined)[] = [];
			const { c, seen } = caller(runs, {
				ps: psOf({ ...table, [process.pid]: [1, 1, "bun meerkat-shepherd"] }),
				request: async (method, url, _token, timeoutMs) => {
					seen.requests.push(`${method} ${url}`);
					timeouts.push(timeoutMs);
					return reply as Reply;
				},
			});
			c.dir = started(runs, { served, port });
			c.owned = true;
			c.held = true;
			await c.leave("stopped waiting (SIGTERM)");
			expect(seen.stderr).toBe(said);
			expect(seen.kills).toEqual(stops ? [`SIGTERM ${process.pid}`] : []);
			expect(seen.requests).toEqual(port ? ["POST http://127.0.0.1:4242/api/attach/leave?run=run"] : []);
			if (port) expect(timeouts).toEqual([2000]);
		});
	}

	// A rerun that has not heard from the backend only hands the run back to
	// the caller it replaced.
	test("as a rerun that has not heard from its backend only hands it back", async () => {
		const runs = tmp();
		const { c, seen } = caller(runs);
		c.dir = started(runs, { served: true, port: true });
		writeFileSync(join(c.dir, "caller"), "100\n");
		c.owned = true;
		c.held = false;
		c.prevCaller = "42";
		await c.leave("stopped waiting (SIGTERM)");
		expect(readFileSync(join(c.dir, "caller"), "utf8")).toBe("42\n");
		expect(seen.requests).toEqual([]);
		expect(seen.kills).toEqual([]);
		expect(seen.stderr).toBe(rerun);
	});
});

describe("a caller whose backend is dead", () => {
	// A runs dir holding run key.r, whose port file names BEAM pid 999999.
	function buryRuns() {
		const runs = tmp();
		mkdirSync(join(runs, "key.r"));
		writeFileSync(join(runs, "key.r/port"), "4242 999999\n");
		return runs;
	}

	// As when the caller was suspended after `serverAlive` found the pid
	// file, and meanwhile the backend finished and a rerun removed the run:
	// the backend did decide, so the next pass says the run was removed.
	test("whose run is removed after its pid check does not say its backend died", async () => {
		const { c, seen } = caller(tmp());
		c.dir = join(c.runs, "key.r");
		c.owned = true;
		c.held = true;
		expect(await exitCode(() => c.buryServer())).toBe(null);
		expect(seen.stderr).toBe("");
	});

	test("whose run is removed while it checks the BEAM does not say its backend died", async () => {
		const runs = buryRuns();
		const { c, seen } = caller(runs, {
			ps: (args) => {
				if (args.includes("command=")) rmSync(join(runs, "key.r"), { recursive: true });
				return { out: "x\n", killed: false };
			},
		});
		c.dir = join(runs, "key.r");
		c.owned = true;
		c.held = true;
		expect(await exitCode(() => c.buryServer())).toBe(null);
		expect(seen.stderr).toBe("");
	});

	// A signal to the caller's whole process group can kill the ps that
	// checks the BEAM's pid, which may since have been reused.
	test("whose check of the BEAM is killed by a signal does not kill that pid", () => {
		const runs = buryRuns();
		const { c, seen } = caller(runs, { ps: () => ({ out: "", killed: true }) });
		c.dir = join(runs, "key.r");
		c.buryServer();
		expect(seen.kills).toEqual([]);
		expect(existsSync(join(runs, "key.r"))).toBe(false);
	});

	test("kills the BEAM its backend left when ps shows it running meerkat", () => {
		const runs = buryRuns();
		const { c, seen } = caller(runs, { ps: psOf({ ...table, 999999: [1, 1, "beam.smp meerkat"] }) });
		c.dir = join(runs, "key.r");
		c.buryServer();
		expect(seen.kills).toEqual(["SIGKILL 999999"]);
	});

	// An unreadable port file fails the read the way one removed after the
	// check does.
	test("whose port file cannot be read buries the run quietly", () => {
		const runs = buryRuns();
		chmodSync(join(runs, "key.r/port"), 0o000);
		const { c, seen } = caller(runs);
		c.dir = join(runs, "key.r");
		c.buryServer();
		expect(seen.stderr).toBe("");
		expect(existsSync(join(runs, "key.r"))).toBe(false);
	});

	test("whose pid file cannot be read takes the backend for dead", () => {
		const run = tmp();
		writeFileSync(join(run, "pid"), `${process.pid}\n`);
		chmodSync(join(run, "pid"), 0o000);
		const { c } = caller(run);
		c.dir = run;
		expect(c.serverAlive()).toBe(false);
	});
});

describe("a caller waiting for its backend's pid", () => {
	test("waits about 10 s by the clock", () => {
		const run = tmp();
		const { c, tick } = caller(run);
		c.dir = run;
		expect(c.serverAlive()).toBe(true);
		tick(9_900);
		expect(c.serverAlive()).toBe(true);
		tick(200);
		expect(c.serverAlive()).toBe(false);
	});

	test("gives the next run it finds a fresh wait", () => {
		const runs = tmp();
		mkdirSync(join(runs, "key.old"));
		mkdirSync(join(runs, "key.new"));
		symlinkSync("key.new", join(runs, "key"));
		const { c, tick } = caller(runs);
		c.dir = join(runs, "key.old");
		c.serverAlive();
		tick(60_000);
		expect(c.findServer()).toBe(true);
		expect(c.dir).toBe(join(runs, "key.new"));
		expect(c.serverAlive()).toBe(true);
	});

	// The pid comes late, then the review runs a minute and loses it, as
	// `restoreRunFiles` allows for.
	test("gives a pid that goes missing after it appeared a fresh wait", () => {
		const run = tmp();
		const { c, tick } = caller(run, { ps: psOf({ ...table, [process.pid]: [1, 1, "bun meerkat"] }) });
		c.dir = run;
		c.serverAlive();
		writeFileSync(join(run, "pid"), `${process.pid}\n`);
		expect(c.serverAlive()).toBe(true);
		rmSync(join(run, "pid"));
		tick(60_000);
		expect(c.serverAlive()).toBe(true);
	});
});

test("a caller dropping a run the key no longer names leaves an older meerkat's run dir in place", () => {
	const runs = tmp();
	mkdirSync(join(runs, "key"));
	const { c } = caller(runs);
	expect(c.retire(join(runs, "key.finished"))).toBe(true);
	expect(existsSync(join(runs, "key.retiring.run"))).toBe(false);
	expect(lstatSync(join(runs, "key")).isDirectory()).toBe(true);
});

// Runs the Bun-run shepherd from `base`/repo with the runs dir given, on a
// fake release whose BEAM records FROM_DOTENV in `base`/seen and
// approves. It is killed within the test's own 5 s, should its caller
// spin.
function shepherdIn(base: string, runs: string) {
	const repo = join(base, "repo");
	mkdirSync(repo, { recursive: true });
	const release = join(base, "release");
	mkdirSync(join(release, "bin"), { recursive: true });
	writeFileSync(join(release, "bin/meerkat"), `#!/bin/sh\necho "\${FROM_DOTENV-unset}" >'${base}/seen'\nexit 76\n`);
	chmodSync(join(release, "bin/meerkat"), 0o755);
	symlinkSync(release, join(base, "current"));
	return Bun.spawnSync([join(import.meta.dir, "../meerkat-shepherd"), "--no-open"], {
		cwd: repo,
		env: { ...process.env, MEERKAT_CURRENT_LINK: join(base, "current"), MEERKAT_RUNS_DIR: runs },
		stderr: "pipe",
		timeout: 4000,
		killSignal: "SIGKILL",
	});
}

// The caller reads no stray file in the reviewed repo's working
// directory: neither a file named `exit` nor, through Bun, its `.env` or
// `bunfig.toml`.
test("a review in a repo holding `exit`, `.env` and `bunfig.toml` files runs as in any other", () => {
	const base = tmp();
	const repo = join(base, "repo");
	mkdirSync(repo);
	writeFileSync(join(repo, "exit"), "0\n");
	writeFileSync(join(repo, ".env"), "FROM_DOTENV=leaked\n");
	writeFileSync(join(repo, "bunfig.toml"), 'preload = ["./preload.ts"]\n');
	writeFileSync(join(repo, "preload.ts"), "process.exit(9);\n");
	const run = shepherdIn(base, join(base, "runs"));
	expect([run.exitCode, run.stderr.toString(), readFileSync(join(base, "seen"), "utf8")]).toEqual([0, "", "unset\n"]);
});

test("a launcher that cannot create its runs dir exits 2 with a REJECT", () => {
	const base = tmp();
	writeFileSync(join(base, "file"), "");
	const run = shepherdIn(base, join(base, "file/runs"));
	expect(run.exitCode).toBe(2);
	expect(run.stderr.toString()).toEndWith("meerkat: the launcher failed — defaulting to REJECT (commit aborted).\n");
});

// An old-layout run dir in a runs dir that cannot be changed: removing it
// fails, and the caller exits with the decision all the same.
test("a caller keeps a decision it cannot clean up after", async () => {
	const runs = tmp();
	const { c } = caller(runs, { stream: outcome });
	c.dir = c.link;
	mkdirSync(c.dir);
	writeFileSync(join(c.dir, "port"), "4242 1\n");
	writeFileSync(join(c.dir, "token"), "token\n");
	writeFileSync(join(c.dir, "exit"), "1\n");
	writeFileSync(join(c.dir, "sub"), "");
	chmodSync(c.dir, 0o555);
	try {
		expect(await exitCode(c.attachStream({}))).toBe(1);
	} finally {
		chmodSync(c.dir, 0o755);
	}
});

describe("a real caller's requests", () => {
	test("report a deadline that ended one", async () => {
		const server = Bun.serve({ port: 0, fetch: () => new Promise<Response>(() => {}) });
		try {
			expect(await realDeps.request("POST", `http://127.0.0.1:${server.port}/`, "t", 50)).toEqual({
				status: 0,
				body: "",
				timedOut: true,
			});
		} finally {
			server.stop(true);
		}
	});

	test("read the attach stream's frames whole, however its reads split them", async () => {
		const encode = (text: string) => new TextEncoder().encode(text);
		const server = Bun.serve({
			port: 0,
			fetch: () =>
				new Response(
					new ReadableStream({
						async start(controller) {
							controller.enqueue(encode("o out"));
							await Bun.sleep(20);
							controller.enqueue(encode("come\nx 1\n"));
							controller.close();
						},
					}),
				),
		});
		const lines: string[] = [];
		try {
			const status = await realDeps.stream(
				`http://127.0.0.1:${server.port}/`,
				"t",
				new AbortController().signal,
				(line) => lines.push(line),
				() => {},
			);
			expect([status, lines]).toEqual([200, ["o outcome", "x 1"]]);
		} finally {
			server.stop(true);
		}
	});
});

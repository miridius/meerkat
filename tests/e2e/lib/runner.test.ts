import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { describe, expect, setDefaultTimeout, test } from "bun:test";
import { makeFixture, OWNED_TMP_PARENT } from "./fixture.js";
import { elapsedSeconds, reapOrphanedBackends, reapOrphanedFixtures, startMeerkat } from "./runner.js";

// These tests start processes, which on a loaded machine can take longer
// than bun's 5 s default; a timed-out test also has bun kill them mid-run.
setDefaultTimeout(30_000);

// spawnSync rather than awaiting spawn's "exit": under load bun sometimes
// sets exitCode on a child without ever emitting "exit".
function exitedPid(): number {
	return spawnSync("true").pid;
}

function backend(runsDir: string): number {
	const proc = spawn("sleep", ["60"], { detached: true, stdio: "ignore" });
	proc.unref();
	const pid = proc.pid as number;
	mkdirSync(join(runsDir, "run"));
	writeFileSync(join(runsDir, "run", "pid"), String(pid));
	return pid;
}

function alive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
}

// bun runs a file's tests one at a time, which the reaper tests need: each
// reap scans all of `OWNED_TMP_PARENT`, so one test's reap must not run while
// another is still arranging its runs dirs.
describe("orphaned backend reaper", () => {
	test("stops backends whose owning test process has exited and keeps those of a live one", async () => {
		const orphaned = mkdtempSync(join(OWNED_TMP_PARENT, `meerkat-runs-${exitedPid()}-`));
		const owned = mkdtempSync(join(OWNED_TMP_PARENT, `meerkat-runs-${process.pid}-`));
		const orphan = backend(orphaned);
		const kept = backend(owned);
		try {
			await reapOrphanedBackends();

			expect(alive(orphan), "backend of an exited owner is stopped").toBe(false);
			expect(existsSync(orphaned), "runs dir of an exited owner is removed").toBe(false);
			expect(alive(kept), "backend of a live owner keeps running").toBe(true);
			expect(existsSync(owned), "runs dir of a live owner is kept").toBe(true);
		} finally {
			for (const pid of [orphan, kept]) {
				try {
					process.kill(pid, "SIGKILL");
				} catch {}
			}
			rmSync(orphaned, { recursive: true, force: true });
			rmSync(owned, { recursive: true, force: true });
		}
	});

	test("leaves alone a process that took over a dead backend's pid", async () => {
		const orphaned = mkdtempSync(join(OWNED_TMP_PARENT, `meerkat-runs-${exitedPid()}-`));
		const bystander = backend(orphaned);
		// The pid file predates the process now holding its pid, as when the
		// backend exited long ago and the OS reused its pid.
		const written = new Date(Date.now() - 60_000);
		utimesSync(join(orphaned, "run", "pid"), written, written);
		try {
			await reapOrphanedBackends();

			expect(alive(bystander), "a later process holding the recorded pid keeps running").toBe(true);
			expect(existsSync(orphaned), "runs dir of an exited owner is removed").toBe(false);
		} finally {
			try {
				process.kill(bystander, "SIGKILL");
			} catch {}
			rmSync(orphaned, { recursive: true, force: true });
		}
	});

	test("leaves alone runs dirs whose name carries no owner pid", async () => {
		// Named like the runs dirs of older test runs.
		const unowned = mkdtempSync(join(OWNED_TMP_PARENT, "meerkat-runs-"));
		const kept = backend(unowned);
		try {
			await reapOrphanedBackends();

			expect(alive(kept), "backend in a dir without an owner pid keeps running").toBe(true);
			expect(existsSync(unowned), "runs dir without an owner pid is kept").toBe(true);
		} finally {
			try {
				process.kill(kept, "SIGKILL");
			} catch {}
			rmSync(unowned, { recursive: true, force: true });
		}
	});
});

describe("orphaned fixture reaper", () => {
	test("removes the fixtures of a test process killed before cleanup and keeps those of a live one", () => {
		// A test process SIGKILLed mid-test never reaches fixture cleanup.
		const killed = spawnSync(
			"bun",
			[
				"-e",
				`import { makeFixture, makePrFixture } from ${JSON.stringify(join(import.meta.dir, "fixture.ts"))};
				const pr = makePrFixture();
				console.log(JSON.stringify([makeFixture().dir, pr.dir, pr.ghStubDir]));
				process.kill(process.pid, "SIGKILL");`,
			],
			{ encoding: "utf8" },
		);
		expect(killed.signal).toBe("SIGKILL");
		const orphaned: string[] = JSON.parse(killed.stdout);
		const owned = makeFixture();
		try {
			reapOrphanedFixtures();

			for (const dir of orphaned) expect(existsSync(dir), `${dir} of a killed owner is removed`).toBe(false);
			expect(
				readdirSync(OWNED_TMP_PARENT).filter((name) =>
					new RegExp(`^meerkat-(?:e2e|rr)[a-z-]*-${killed.pid}-[A-Za-z0-9]{6}$`).test(name),
				),
				"no dir of the killed owner is left",
			).toEqual([]);
			expect(existsSync(owned.dir), "fixture of a live owner is kept").toBe(true);
		} finally {
			for (const dir of orphaned) rmSync(dir, { recursive: true, force: true });
			owned.cleanup();
		}
	});

	test("leaves alone fixture dirs whose name carries no owner pid", () => {
		// Named like the fixtures of older test runs; without an owner pid the
		// reaper cannot tell whether the run using it is over.
		const unowned = mkdtempSync(join(OWNED_TMP_PARENT, "meerkat-e2e-"));
		try {
			reapOrphanedFixtures();

			expect(existsSync(unowned), "fixture dir without an owner pid is kept").toBe(true);
		} finally {
			rmSync(unowned, { recursive: true, force: true });
		}
	});
});

test("the reapers list only their own parent dir, not the whole OS temp dir", async () => {
	// Named like an orphaned fixture and runs dir, but where listing would
	// mean reading every entry of the OS temp dir.
	const outside = [
		mkdtempSync(join(tmpdir(), `meerkat-e2e-${exitedPid()}-`)),
		mkdtempSync(join(tmpdir(), `meerkat-runs-${exitedPid()}-`)),
	];
	try {
		await reapOrphanedBackends();
		reapOrphanedFixtures();

		for (const dir of outside) expect(existsSync(dir), `${dir} outside the parent is not listed`).toBe(true);
	} finally {
		for (const dir of outside) rmSync(dir, { recursive: true, force: true });
	}
});

test("a meerkat that exits before printing its URL leaves no backend, fixture, runs or config dir behind", async () => {
	const dir = mkdtempSync(join(tmpdir(), "meerkat-start-"));
	const seen = join(dir, "seen");
	// Starts a backend and records it the way meerkat-attach does, then
	// exits without a review URL.
	const bin = join(dir, "meerkat");
	writeFileSync(
		bin,
		`#!/bin/sh
mkdir -p "$MEERKAT_RUNS_DIR/run" "$XDG_CONFIG_HOME/meerkat"
sleep 60 </dev/null >/dev/null 2>&1 &
echo $! > "$MEERKAT_RUNS_DIR/run/pid"
echo "$MEERKAT_RUNS_DIR $! $XDG_CONFIG_HOME" > "$SEEN"
echo boom >&2
exit 1
`,
		{ mode: 0o755 },
	);
	let cleaned = false;
	let pid = 0;
	try {
		const start = startMeerkat({
			bin,
			args: [],
			fixture: { dir, cleanup: () => (cleaned = true) },
			env: { SEEN: seen },
		});

		await expect(start).rejects.toThrow(/exited \(code=1\) before printing review URL[\s\S]*boom/);
		const [runsDir, recorded, configHome] = readFileSync(seen, "utf8").trim().split(" ");
		pid = Number(recorded);
		expect(dirname(runsDir), "runs dir is where the reapers look").toBe(OWNED_TMP_PARENT);
		expect(alive(pid), "backend is stopped").toBe(false);
		expect(existsSync(runsDir), "runs dir is removed").toBe(false);
		expect(configHome, "settings stay out of the user's config dir").toBe(`${runsDir}cfg`);
		expect(existsSync(configHome), "config dir is removed").toBe(false);
		expect(cleaned, "fixture is cleaned up").toBe(true);
	} finally {
		if (pid > 0 && alive(pid)) process.kill(pid, "SIGKILL");
		rmSync(dir, { recursive: true, force: true });
	}
});

test("a meerkat that exits before printing its URL reports stderr read after it exited", async () => {
	const dir = mkdtempSync(join(tmpdir(), "meerkat-start-"));
	// A child holding stderr writes to it after meerkat has exited, standing
	// in for output still unread in the pipe when "exit" is emitted.
	const bin = join(dir, "meerkat");
	writeFileSync(bin, "#!/bin/sh\n(sleep 0.5; echo boom >&2) &\nexit 1\n", { mode: 0o755 });
	try {
		await expect(startMeerkat({ bin, args: [], fixture: { dir } })).rejects.toThrow(
			/exited \(code=1\) before printing review URL[\s\S]*boom/,
		);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

test("meerkat's git reads no config but the tests' global config", async () => {
	const dir = mkdtempSync(join(tmpdir(), "meerkat-start-"));
	const seen = join(dir, "seen");
	const bin = join(dir, "meerkat");
	writeFileSync(bin, `#!/bin/sh\ngit config --list --show-scope > "$SEEN"\nexit 1\n`, { mode: 0o755 });
	// Config a caller's `git -c` or GIT_CONFIG_COUNT would inject.
	const injected = {
		GIT_CONFIG_PARAMETERS: "'meerkat.injected'='1'",
		GIT_CONFIG_COUNT: "1",
		GIT_CONFIG_KEY_0: "meerkat.counted",
		GIT_CONFIG_VALUE_0: "1",
	};
	const previous = Object.fromEntries(Object.keys(injected).map((key) => [key, process.env[key]]));
	Object.assign(process.env, injected);
	try {
		await expect(startMeerkat({ bin, args: [], fixture: { dir }, env: { SEEN: seen } })).rejects.toThrow();
		expect(readFileSync(seen, "utf8")).toBe(
			"global\tmaintenance.auto=false\nglobal\tcore.logallrefupdates=false\nglobal\tinit.templatedir=\nglobal\ttransfer.unpacklimit=1\nglobal\tpack.writereverseindex=false\n",
		);
	} finally {
		for (const [key, value] of Object.entries(previous)) {
			if (value === undefined) delete process.env[key];
			else process.env[key] = value;
		}
		rmSync(dir, { recursive: true, force: true });
	}
});

describe("ps elapsed-time parsing", () => {
	for (const [etime, seconds] of [
		["00:07", 7],
		["12:34", 12 * 60 + 34],
		["01:02:03", 3600 + 2 * 60 + 3],
		["06-17:20:15", ((6 * 24 + 17) * 60 + 20) * 60 + 15],
	] as const) {
		test(`reads ${etime} as ${seconds} s`, () => {
			expect(elapsedSeconds(etime)).toBe(seconds);
		});
	}

	test("rejects a format it does not know", () => {
		expect(() => elapsedSeconds("1h")).toThrow("unrecognised ps etime");
	});
});

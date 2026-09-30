import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";
import { elapsedSeconds, reapOrphanedBackends, startMeerkat } from "./runner.js";

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
// reap scans the whole temp dir, so one test's reap must not run while
// another is still arranging its runs dirs.
describe("orphaned backend reaper", () => {
	test("stops backends whose owning test process has exited and keeps those of a live one", async () => {
		const orphaned = mkdtempSync(join(tmpdir(), `meerkat-runs-${exitedPid()}-`));
		const owned = mkdtempSync(join(tmpdir(), `meerkat-runs-${process.pid}-`));
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
		const orphaned = mkdtempSync(join(tmpdir(), `meerkat-runs-${exitedPid()}-`));
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
		// Named like the runs dirs of older test runs; meerkat's own `meerkat-runs`
		// in the same temp dir likewise has no pid in its name.
		const unowned = mkdtempSync(join(tmpdir(), "meerkat-runs-"));
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

test("a meerkat that exits before printing its URL leaves no backend, fixture or runs dir behind", async () => {
	const dir = mkdtempSync(join(tmpdir(), "meerkat-start-"));
	const seen = join(dir, "seen");
	// Starts a backend and records it the way meerkat-attach does, then
	// exits without a review URL.
	const bin = join(dir, "meerkat");
	writeFileSync(
		bin,
		`#!/bin/sh
mkdir -p "$MEERKAT_RUNS_DIR/run"
sleep 60 </dev/null >/dev/null 2>&1 &
echo $! > "$MEERKAT_RUNS_DIR/run/pid"
echo "$MEERKAT_RUNS_DIR $!" > "$SEEN"
echo boom >&2
exit 1
`,
		{ mode: 0o755 },
	);
	let cleaned = false;
	try {
		const start = startMeerkat({
			bin,
			args: [],
			fixture: { dir, cleanup: () => (cleaned = true) },
			env: { SEEN: seen },
		});

		await expect(start).rejects.toThrow(/exited \(code=1\) before printing review URL[\s\S]*boom/);
		const [runsDir, pid] = readFileSync(seen, "utf8").trim().split(" ");
		expect(alive(Number(pid)), "backend is stopped").toBe(false);
		expect(existsSync(runsDir), "runs dir is removed").toBe(false);
		expect(cleaned, "fixture is cleaned up").toBe(true);
	} finally {
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

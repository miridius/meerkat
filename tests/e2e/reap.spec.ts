import { spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "@playwright/test";
import { reapOrphanedBackends } from "./lib/runner.js";

async function exitedPid(): Promise<number> {
	const proc = spawn("true");
	await new Promise((resolve) => proc.once("exit", resolve));
	return proc.pid as number;
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

test.describe("orphaned backend reaper", () => {
	test("stops backends whose owning test process has exited and keeps those of a live one", async () => {
		const orphaned = mkdtempSync(join(tmpdir(), `meerkat-runs-${await exitedPid()}-`));
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
});

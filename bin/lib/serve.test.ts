import { expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { status } from "./serve.ts";

test("status gives a command killed by a signal 128 plus its number, as bash does", () => {
	expect(status(Bun.spawnSync(["sh", "-c", "kill -KILL $$"]))).toBe(137);
	expect(status(Bun.spawnSync(["sh", "-c", "exit 3"]))).toBe(3);
});

test("launch ends a launcher that throws with 2 and a REJECT, not the reviewer's 1", () => {
	const serve = join(import.meta.dir, "serve.ts");
	const dir = mkdtempSync(join(tmpdir(), "meerkat-launch-"));
	const script = join(dir, "throwing.ts");
	writeFileSync(script, `import { launch } from "${serve}";\nawait launch(async () => { throw new Error("boom"); });\n`);
	const launchThrowing = (...args: string[]) =>
		Bun.spawnSync([process.execPath, script, ...args], { stderr: "pipe" });
	try {
		const run = launchThrowing();
		expect(run.exitCode).toBe(2);
		expect(run.stderr.toString()).toMatch(
			/^Error: boom\n\s+at [\s\S]*\nmeerkat: the launcher failed — defaulting to REJECT \(commit aborted\)\.\n$/,
		);
		const answers = launchThrowing("--answers");
		expect(answers.exitCode).toBe(2);
		expect(answers.stderr.toString()).toEndWith("\nmeerkat: the launcher failed — the answers were not stored.\n");
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

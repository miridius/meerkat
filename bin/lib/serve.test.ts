import { expect, test } from "bun:test";
import { join } from "node:path";
import { status } from "./serve.ts";

test("status gives a command killed by a signal 128 plus its number, as bash does", () => {
	expect(status(Bun.spawnSync(["sh", "-c", "kill -KILL $$"]))).toBe(137);
	expect(status(Bun.spawnSync(["sh", "-c", "exit 3"]))).toBe(3);
});

test("launch ends a launcher that throws with 2 and a REJECT, not the reviewer's 1", () => {
	const serve = join(import.meta.dir, "serve.ts");
	const run = Bun.spawnSync(
		[process.execPath, "-e", `import { launch } from "${serve}"; await launch(async () => { throw new Error("boom"); });`],
		{ stderr: "pipe" },
	);
	expect([run.exitCode, run.stderr.toString()]).toEqual([
		2,
		"meerkat: boom — defaulting to REJECT (commit aborted).\n",
	]);
});

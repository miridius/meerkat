import { expect, test } from "bun:test";
import { status } from "./serve.ts";

test("status gives a command killed by a signal 128 plus its number, as bash does", () => {
	expect(status(Bun.spawnSync(["sh", "-c", "kill -KILL $$"]))).toBe(137);
	expect(status(Bun.spawnSync(["sh", "-c", "exit 3"]))).toBe(3);
});

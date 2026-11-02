import { expect, test } from "./lib/test";
import { startMeerkat } from "./lib/runner";

// The seam is a backend that exits before it serves a review: the caller
// relays its log and exit code, here from `parse_args`'s System.halt(64),
// which ExUnit cannot reach. The review targets themselves, and the other
// rejections, are covered by ExUnit.
test.describe("rejected invocations", () => {
	test("an unrecognised option exits 64 and names the option", async () => {
		const runner = await startMeerkat({ args: ["--bogus"], port: null, awaitUrl: false });
		try {
			const { code } = await runner.awaitExit();
			const stderr = await runner.awaitClose();
			expect(code).toBe(64);
			// Matched as a whole line: a crash's stack trace can quote the
			// same text inside `no case clause matching: "..."`.
			expect(stderr).toMatch(/^meerkat: unrecognised options: --bogus$/m);
		} finally {
			await runner.kill();
		}
	});
});

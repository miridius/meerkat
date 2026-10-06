import { spawnSync } from "node:child_process";
import { expect, test } from "./lib/test";
import { makeFixture } from "./lib/fixture";
import { MEERKAT_BIN } from "./lib/runner";

// The seam is a backend that exits before it serves a review: the caller
// relays its log and exit code, here from `parse_args`'s System.halt(64),
// which ExUnit cannot reach. The review targets themselves, and the other
// rejections, are covered by ExUnit.
test.describe("rejected invocations", () => {
	test("an unrecognised option exits 64 and names the option", () => {
		const fixture = makeFixture();
		try {
			const result = spawnSync(MEERKAT_BIN, ["--bogus", "--no-open"], {
				cwd: fixture.dir,
				stdio: ["ignore", "ignore", "pipe"],
				timeout: 60_000,
				encoding: "utf8",
			});
			expect(result.status).toBe(64);
			// Matched as a whole line: a crash's stack trace can quote the
			// same text inside `no case clause matching: "..."`.
			expect(result.stderr).toMatch(/^meerkat: unrecognised options: --bogus$/m);
		} finally {
			fixture.cleanup();
		}
	});
});

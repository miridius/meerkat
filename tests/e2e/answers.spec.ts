import { spawnSync } from "node:child_process";
import { makeFixture } from "./lib/fixture";
import { MEERKAT_BIN } from "./lib/runner";
import { expect, test } from "./lib/test";

// The seam is the launcher's `--answers` branch, which runs the BEAM in the
// foreground so the caller's stdin reaches it. Which spellings of the flag
// take that branch is covered by test/scripts/shepherd_test.exs; validation,
// storage and the banner the next review shows by the other ExUnit tests.
test.describe("meerkat --answers", () => {
	test("--answers stores the answers piped on stdin", () => {
		const fixture = makeFixture();
		const input = JSON.stringify({
			answers: [{ location: "global", question: "why?", answer: "because" }],
		});

		try {
			const result = spawnSync(MEERKAT_BIN, ["--answers"], {
				cwd: fixture.dir,
				input,
				stdio: ["pipe", "ignore", "pipe"],
				timeout: 60_000,
				encoding: "utf8",
			});
			expect(result.status).toBe(0);
			expect(result.stderr).toContain("meerkat: stored 1 answer.");
		} finally {
			fixture.cleanup();
		}
	});
});

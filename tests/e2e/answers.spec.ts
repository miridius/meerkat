import { spawnSync } from "node:child_process";
import { makeFixture } from "./lib/fixture";
import { MEERKAT_BIN } from "./lib/runner";
import { expect, test } from "./lib/test";

// The seam is the launcher's `--answers` branch, which runs the BEAM in the
// foreground so the caller's stdin reaches it. Validation, storage and the
// banner the next review shows are covered by ExUnit.
test.describe("meerkat --answers", () => {
	for (const flag of ["--answers", "--answers=true"]) {
		test(`${flag} stores the answers piped on stdin`, () => {
			const fixture = makeFixture();
			const input = JSON.stringify({
				answers: [{ location: "global", question: "why?", answer: "because" }],
			});

			try {
				const result = spawnSync(MEERKAT_BIN, [flag], {
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
	}
});

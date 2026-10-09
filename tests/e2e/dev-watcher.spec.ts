import { readFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test } from "./lib/test";
import { startMeerkat } from "./lib/runner";

// The seam is the dev BEAM's supervisor start, which ExUnit cannot reach:
// `Meerkat.DevWatcher` compiles only under MIX_ENV=dev.
test.describe("dev watcher", () => {
	test("a review still opens when the file watcher cannot start", async ({ page }) => {
		// file_system's macOS backend finds no listener at this path, so its
		// worker's start returns :ignore.
		const meerkat = await startMeerkat({
			env: { FILESYSTEM_FSMAC_EXECUTABLE_FILE: "/nonexistent/mac_listener" },
		});
		const logPath = join(meerkat.fixture.dir, ".git", "meerkat-precommit", "meerkat.log");
		try {
			await page.goto(meerkat.url);
			await expect(page.locator(".file-section").first()).toBeVisible();
			await expect
				.poll(() => readFileSync(logPath, "utf8"))
				.toContain("couldn't start file_system");
		} finally {
			await meerkat.kill();
		}
	});
});

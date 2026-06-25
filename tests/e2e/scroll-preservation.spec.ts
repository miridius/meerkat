import { expect, test } from "./lib/test";
import { startMeerkat } from "./lib/runner";
import { makeFixture } from "./lib/fixture";

// A live-restart onto a version with changed assets makes phx-track-static
// reload the page on socket reconnect. A plain page.reload() reproduces
// that full reload (same origin, so sessionStorage survives), which is the
// behaviour the scroll-preservation code in app.js has to handle.
test.describe("scroll preservation across reload", () => {
	const tallFile = `${Array.from({ length: 400 }, (_, i) => `line ${i + 1}`).join("\n")}\n`;

	test("restores the scroll position after a reload", async ({ page }) => {
		const meerkat = await startMeerkat({
			fixture: makeFixture({ files: { "tall.txt": tallFile } }),
		});
		try {
			await page.goto(meerkat.url);
			await expect(
				page.getByRole("button", { name: /tall\.txt/ }),
			).toBeVisible();

			// The reload the scroll code preserves across is triggered by
			// phx-track-static (LiveView full-reloads on reconnect when the
			// version's assets changed), so confirm those tags are present.
			expect(
				await page.locator("script[phx-track-static]").count(),
			).toBeGreaterThan(0);

			await page.evaluate(() => window.scrollTo(0, 1500));
			await expect
				.poll(() => page.evaluate(() => Math.round(window.scrollY)))
				.toBeGreaterThan(1000);
			const before = await page.evaluate(() => Math.round(window.scrollY));

			// Let the 200ms stash debounce write to sessionStorage.
			await page.waitForTimeout(350);
			await page.reload();

			await expect
				.poll(() => page.evaluate(() => Math.round(window.scrollY)), {
					timeout: 5000,
				})
				.toBeGreaterThan(before - 100);
		} finally {
			await meerkat.kill();
		}
	});

	test("a fresh review with no stashed position starts at the top", async ({
		page,
	}) => {
		const meerkat = await startMeerkat({
			fixture: makeFixture({ files: { "tall.txt": tallFile } }),
		});
		try {
			await page.goto(meerkat.url);
			await expect(
				page.getByRole("button", { name: /tall\.txt/ }),
			).toBeVisible();

			// No prior scroll was stashed for this origin, so the restore is a
			// no-op and the page stays at the top.
			await page.waitForTimeout(350);
			expect(await page.evaluate(() => Math.round(window.scrollY))).toBe(0);
		} finally {
			await meerkat.kill();
		}
	});
});

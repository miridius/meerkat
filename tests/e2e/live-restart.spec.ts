import { expect, test } from "./lib/test";
import { startMeerkat } from "./lib/runner";
import { makeVersionLink } from "./lib/fixture";

test.describe("live restart", () => {
	test("the open tab reconnects to the respawned BEAM without reloading", async ({ page }) => {
		const version = makeVersionLink();
		const meerkat = await startMeerkat({ env: { MEERKAT_CURRENT_LINK: version.link } });
		try {
			await page.goto(meerkat.url);
			const view = page.locator("[data-phx-main]");
			await expect(view).toHaveClass(/phx-connected/);
			await page.evaluate(() => {
				(window as unknown as { notReloaded: boolean }).notReloaded = true;
			});

			version.flip();

			await expect(view).toHaveClass(/phx-error/, { timeout: 15_000 });
			await expect(view).toHaveClass(/phx-connected/, { timeout: 30_000 });
			await page.getByRole("button", { name: /^\+ Add global comment$/ }).click();
			await expect(page.locator(".comment-form")).toBeVisible();
			expect(
				await page.evaluate(() => (window as unknown as { notReloaded?: boolean }).notReloaded),
			).toBe(true);
		} finally {
			await meerkat.kill();
			version.cleanup();
		}
	});
});

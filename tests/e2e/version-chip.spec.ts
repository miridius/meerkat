import { rmSync } from "node:fs";
import { manifestRoot } from "./lib/fixture";
import { expect, test } from "./lib/test";
import { startMeerkat } from "./lib/runner";

const PROD_MANIFEST = [
	"abc1234567890",
	"https://github.com/miridius/meerkat",
	"Live-restart a review onto a newly-installed version (#11)",
	"Install versioned releases (#10)",
];

// The chip's browser seam: the popover and the localStorage-backed
// badge. What a dev and a prod build render is covered by the LiveView
// tests.
test.describe("version chip", () => {
	test("a prod build's chip opens a changelog popover, and its badge counts entries newer than last seen until opened, in every tab", async ({
		page,
		context,
	}) => {
		const releaseRoot = manifestRoot(PROD_MANIFEST);
		const meerkat = await startMeerkat({ env: { RELEASE_ROOT: releaseRoot } });
		try {
			await page.goto(meerkat.url);
			const chip = page.locator(".version-chip-btn");
			const popover = page.locator(".version-popover");
			const badge = page.locator(".version-badge");
			await expect(chip.locator(".chip-value")).toHaveText("abc1234");
			await expect(badge, "a first visit treats the current version as seen").toBeHidden();
			await expect(popover).toBeHidden();

			await chip.click();
			await expect(popover).toBeVisible();
			await expect(
				popover.getByRole("link", { name: /#11.*Live-restart/ }),
			).toHaveAttribute("href", "https://github.com/miridius/meerkat/pull/11");
			await expect(popover.getByRole("link", { name: /#10/ })).toBeVisible();
			await page.keyboard.press("Escape");
			await expect(popover).toBeHidden();

			// Simulate having last acknowledged up to #10, then re-mount.
			await page.evaluate(() => localStorage.setItem("meerkat:lastSeenPr", "10"));
			await page.reload();
			await expect(badge).toBeVisible();
			await expect(badge).toHaveText("1");

			const other = await context.newPage();
			await other.goto(meerkat.url);
			await expect(other.locator(".version-badge")).toHaveText("1");

			await chip.click();
			await expect(badge, "opening the changelog clears the badge").toBeHidden();
			await expect(other.locator(".version-popover"), "every tab opens it").toBeVisible();
			await expect(other.locator(".version-badge")).toBeHidden();
		} finally {
			await meerkat.kill();
			rmSync(releaseRoot, { recursive: true, force: true });
		}
	});
});

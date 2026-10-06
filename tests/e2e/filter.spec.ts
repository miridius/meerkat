import { expect, test } from "./lib/test";
import { startMeerkat } from "./lib/runner";
import { makeFixture } from "./lib/fixture";

// The file-filter sidebar's browser seam: scrolling it into view when it
// opens. What the filter hides, pins and restores is covered by the
// LiveView tests.
test.describe("file filter", () => {
	test("opening the panel while scrolled down brings it into view", async ({ page }) => {
		// A tall file so the page scrolls; the panel lives near the top of
		// the page, above the file list.
		const tall = Array.from({ length: 400 }, (_, i) => `line ${i + 1}`).join("\n");
		const meerkat = await startMeerkat({
			fixture: makeFixture({ files: { "big.txt": `${tall}\n` } }),
		});
		try {
			await page.goto(meerkat.url);

			// Scroll to the bottom of the diff, far from the panel.
			await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
			await expect.poll(() => page.evaluate(() => window.scrollY)).toBeGreaterThan(0);

			// Open the panel from the sticky toolbar button. Without the
			// scroll-into-view push it stays off-screen at the top. The
			// button's accessible name is its aria-label; the visible
			// "☰ Files" string is content, not the accessible name.
			await page.getByRole("button", { name: /^Toggle file list$/ }).click();
			await expect(page.locator(".file-filter-header")).toBeVisible();

			// toBeInViewport only tests the viewport rectangle, so it passes
			// even when the sticky toolbar paints over the header. Compare
			// bounding boxes so the header must clear the toolbar's bottom.
			// Poll to ride out the smooth scroll.
			await expect
				.poll(() =>
					page.evaluate(() => {
						const header = document.querySelector(".file-filter-header")?.getBoundingClientRect();
						const toolbar = document.querySelector(".diff-toolbar")?.getBoundingClientRect();
						if (!header || !toolbar) return false;
						return (
							header.top >= toolbar.bottom - 1 && header.top >= 0 && header.bottom <= window.innerHeight
						);
					}),
				)
				.toBe(true);
		} finally {
			await meerkat.kill();
		}
	});
});

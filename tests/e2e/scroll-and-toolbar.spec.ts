import { rmSync } from "node:fs";
import { makeFixture, manifestRoot } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";
import { expect, test } from "./lib/test";

const PROD_MANIFEST = [
	"abc1234567890",
	"https://github.com/miridius/meerkat",
	"Live-restart a review onto a newly-installed version (#11)",
	"Install versioned releases (#10)",
];

const TALL_FILE = `${Array.from({ length: 400 }, (_, i) => `line ${i + 1}`).join("\n")}\n`;

// Browser seams of a long review's page: the scroll position a reload
// keeps, the file-filter panel scrolled into view when it opens, and the
// version chip's popover and localStorage-backed badge. What the filter
// hides, pins and restores, and what a dev and a prod build's chip
// render, are covered by the LiveView tests.
//
// A live-restart onto a version with changed assets makes
// phx-track-static reload the page on socket reconnect. A plain
// page.reload() reproduces that full reload (same origin, so
// sessionStorage survives), which is the behaviour the
// scroll-preservation code in app.js has to handle.
test("a fresh review starts at the top and a reload keeps its scroll, the file panel scrolls into view, and the version chip's badge counts unseen changes", async ({
	page,
}) => {
	const releaseRoot = manifestRoot(PROD_MANIFEST);
	const meerkat = await startMeerkat({
		fixture: makeFixture({ files: { "tall.txt": TALL_FILE } }),
		env: { RELEASE_ROOT: releaseRoot },
	});
	try {
		await page.goto(meerkat.url);
		await expect(page.getByRole("button", { name: /tall\.txt/ })).toBeVisible();
		const scrollY = () => page.evaluate(() => Math.round(window.scrollY));

		// No prior scroll was stashed for this origin, so the restore is a
		// no-op and the page stays at the top.
		await page.waitForTimeout(350);
		expect(await scrollY()).toBe(0);

		// The reload the scroll code preserves across is triggered by
		// phx-track-static (LiveView full-reloads on reconnect when the
		// version's assets changed), so confirm those tags are present.
		expect(await page.locator("script[phx-track-static]").count()).toBeGreaterThan(0);

		await page.evaluate(() => window.scrollTo(0, 1500));
		await expect.poll(scrollY).toBeGreaterThan(1000);
		const before = await scrollY();
		// Let the 200ms stash debounce write to sessionStorage.
		await page.waitForTimeout(350);
		await page.reload();
		await expect.poll(scrollY).toBeGreaterThan(before - 100);

		// Opening the file panel from the sticky toolbar while scrolled to
		// the bottom brings it into view; without the scroll-into-view push
		// it stays off-screen at the top. The button's accessible name is
		// its aria-label, not its visible "☰ Files" content.
		await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
		await expect.poll(scrollY).toBeGreaterThan(before);
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
					return header.top >= toolbar.bottom - 1 && header.top >= 0 && header.bottom <= window.innerHeight;
				}),
			)
			.toBe(true);

		// A prod build's chip opens a changelog popover, and its badge
		// counts entries newer than the last seen until opened.
		const chip = page.locator(".version-chip-btn");
		const popover = page.locator(".version-popover");
		const badge = page.locator(".version-badge");
		await expect(chip.locator(".chip-value")).toHaveText("abc1234");
		await expect(badge, "a first visit treats the current version as seen").toBeHidden();
		await expect(popover).toBeHidden();

		await chip.click();
		await expect(popover).toBeVisible();
		await expect(popover.getByRole("link", { name: /#11.*Live-restart/ })).toHaveAttribute(
			"href",
			"https://github.com/miridius/meerkat/pull/11",
		);
		await expect(popover.getByRole("link", { name: /#10/ })).toBeVisible();

		// Simulate having last acknowledged up to #10, then re-mount.
		await page.evaluate(() => localStorage.setItem("meerkat:lastSeenPr", "10"));
		await page.reload();
		await expect(badge).toBeVisible();
		await expect(badge).toHaveText("1");

		await chip.click();
		await expect(badge, "opening the changelog clears the badge").toBeHidden();
	} finally {
		await meerkat.kill();
		rmSync(releaseRoot, { recursive: true, force: true });
	}
});

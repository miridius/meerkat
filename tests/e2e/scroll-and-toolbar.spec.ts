import { rmSync } from "node:fs";
import type { BrowserContext, Page } from "@playwright/test";
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

// Toolbar settings live in the config dir's settings.json. A change
// reaches the review's other tabs live over PubSub; another review runs
// in its own BEAM, so its tabs read the file when they load or rejoin.
// A rejoin without a reload, such as after a dropped socket, would also
// have LiveView's form recovery resubmit the page's stale ruler columns,
// saving them over the newer ones.
//
// The other review gets its own browser context: each review's BEAM signs
// its session cookie with its own key, and cookies aren't scoped by port,
// so loading it in the same context would turn the first page's rejoin
// into a full reload.
test("toolbar settings reach the review's other tabs live, and other reviews on load and rejoin", async ({
	page,
	context,
	browser,
}) => {
	const meerkat = await startMeerkat();
	let second: Awaited<ReturnType<typeof startMeerkat>> | undefined;
	const elsewhereContext = await browser.newContext();
	try {
		await page.goto(meerkat.url);
		const other = await openJoined(context, meerkat.url);
		const toolbar = (p: Page) => ({
			wrap: p.getByLabel("Wrap"),
			// Located by CSS, as it is hidden while the settings popover is closed.
			tab8: p.locator("button[phx-value-n='8']"),
			columns: p.getByLabel("Ruler columns"),
			openSettings: () => p.locator(".toolbar-settings > summary").click(),
		});
		const mine = toolbar(page);
		const theirs = toolbar(other);

		await expect(mine.wrap).toBeChecked();
		await mine.wrap.click();
		await mine.openSettings();
		await mine.tab8.click();
		await expect(theirs.wrap).not.toBeChecked();
		await expect(theirs.tab8).toHaveClass(/active/);
		await theirs.openSettings();
		await theirs.columns.fill("60");
		await expect(mine.columns).toHaveValue("60");

		second = await startMeerkat({ env: { XDG_CONFIG_HOME: `${meerkat.runsDir}cfg` } });
		const elsewhere = toolbar(await openJoined(elsewhereContext, second.url));
		await expect(elsewhere.wrap).not.toBeChecked();
		await expect(elsewhere.tab8).toHaveClass(/active/);
		await expect(elsewhere.columns).toHaveValue("60");
		await elsewhere.openSettings();
		await elsewhere.columns.fill("70");
		await expect(elsewhere.columns).toHaveAttribute("value", "70");
		await expect(mine.columns).toHaveValue("60");

		await rejoin(page);
		await expect(mine.columns).toHaveValue("70");
		await expect(mine.wrap).not.toBeChecked();
		await expect(mine.tab8).toHaveClass(/active/);
		const reopened = toolbar(await openJoined(elsewhereContext, second.url));
		await expect(reopened.columns).toHaveValue("70");
	} finally {
		await elsewhereContext.close();
		await second?.kill();
		await meerkat.kill();
	}
});

// A page of `context` at `url`, once its LiveView has joined.
async function openJoined(context: BrowserContext, url: string): Promise<Page> {
	const p = await context.newPage();
	await p.goto(url);
	await expect(p.locator("[data-phx-main]")).toHaveClass(/phx-connected/);
	return p;
}

// Drops the page's connection and resolves once it has rejoined.
function rejoin(p: Page): Promise<void> {
	return p.evaluate(
		() =>
			new Promise<void>((resolve) => {
				const main = document.querySelector("[data-phx-main]") as Element;
				let dropped = false;
				new MutationObserver(() => {
					if (!main.classList.contains("phx-connected")) dropped = true;
					else if (dropped) resolve();
				}).observe(main, { attributes: true, attributeFilter: ["class"] });
				const { liveSocket } = window as unknown as {
					liveSocket: { disconnect: (cb: () => void) => void; connect: () => void };
				};
				liveSocket.disconnect(() => liveSocket.connect());
			}),
	);
}

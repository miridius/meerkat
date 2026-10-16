import { rmSync } from "node:fs";
import type { BrowserContext, Page } from "@playwright/test";
import { makeFixture, manifestRoot } from "./lib/fixture";
import { configHome, startMeerkat } from "./lib/runner";
import { expect, test } from "./lib/test";

const PROD_MANIFEST = [
	"abc1234567890",
	"https://github.com/miridius/meerkat",
	"Live-restart a review onto a newly-installed version (#11)",
	"Install versioned releases (#10)",
];

const TALL_FILE = `${Array.from({ length: 400 }, (_, i) => `line ${i + 1}`).join("\n")}\n`;

// Browser seams of a long review's page: the scroll position a reload
// keeps, and the version chip's popover and localStorage-backed badge.
// What the filter hides, pins and restores, and what a dev and a prod
// build's chip render, are covered by the LiveView tests.
//
// A live-restart onto a version with changed assets makes
// ReviewLive.mount/3 redirect on reconnect for a full page load. A plain
// page.reload() reproduces that full reload (same origin, so
// sessionStorage survives), which is the behaviour the
// scroll-preservation code in app.js has to handle.
test("a fresh review starts at the top and a reload keeps its scroll, and the version chip's badge counts unseen changes", async ({
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

		// ReviewLive.mount/3 uses static_changed?/1 to redirect reconnecting
		// tabs with outdated assets for a full page load. That check uses
		// phx-track-static tags, so confirm those tags are present.
		expect(await page.locator("script[phx-track-static]").count()).toBeGreaterThan(0);

		await page.evaluate(() => window.scrollTo(0, 1500));
		await expect.poll(scrollY).toBeGreaterThan(1000);
		const before = await scrollY();
		// Let the 200ms stash debounce write to sessionStorage.
		await page.waitForTimeout(350);
		await page.reload();
		await expect.poll(scrollY).toBeGreaterThan(before - 100);

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

// The files dropdown's browser seams: it opens over the review from the
// sticky toolbar, below the toolbar even when it wraps, without moving the
// page, and takes focus; Escape, an outside click and a pick close it; a
// pick scrolls to the file without adding a history entry, which would
// stop window.close() closing the tab after a decision; and picking a
// hidden file leaves focus on the button. Its tree, filters and events are
// covered by the LiveView tests.
test("the files dropdown opens over the review, closes on Escape, an outside click and a pick, and a pick adds no history entry", async ({
	page,
}) => {
	const meerkat = await startMeerkat({
		fixture: makeFixture({ files: { "a/tall.txt": TALL_FILE, "b/z.txt": TALL_FILE } }),
	});
	try {
		// Narrow enough that the toolbar wraps onto a second row.
		await page.setViewportSize({ width: 700, height: 720 });
		await page.goto(meerkat.url);
		await expect
			.poll(() => page.evaluate(() => document.querySelector(".diff-toolbar")?.getBoundingClientRect().height))
			.toBeGreaterThan(60);
		const toggle = page.getByRole("button", { name: /^Toggle file list$/ });
		const dropdown = page.getByRole("dialog", { name: "Files" });
		const scrollY = () => page.evaluate(() => Math.round(window.scrollY));
		const historyLength = await page.evaluate(() => history.length);
		// Where `selector`'s top sits relative to the toolbar's bottom, and
		// whether its bottom and right edge are inside the viewport.
		const placement = (selector: string) =>
			page.evaluate((sel) => {
				const el = document.querySelector(sel)?.getBoundingClientRect();
				const bar = document.querySelector(".diff-toolbar")?.getBoundingClientRect();
				if (!el || !bar) return null;
				return {
					below: Math.round(el.top - bar.bottom),
					fits: el.bottom <= window.innerHeight && el.right <= window.innerWidth,
				};
			}, selector);

		await page.evaluate(() => window.scrollTo(0, 1500));
		await expect.poll(scrollY).toBeGreaterThan(1000);
		const scrolled = await scrollY();
		await toggle.click();
		await expect(dropdown).toBeVisible();
		await expect(page.getByRole("textbox", { name: "Filter files" })).toBeFocused();
		const opened = await placement("#file-filter");
		expect(opened?.below).toBeGreaterThanOrEqual(0);
		expect(opened?.fits).toBe(true);
		expect(await scrollY(), "opening does not scroll the page").toBe(scrolled);

		await page.keyboard.press("Escape");
		await expect(dropdown).toBeHidden();
		await expect(toggle).toBeFocused();

		await toggle.click();
		await expect(dropdown).toBeVisible();
		// The page's left margin, clear of the dropdown and of anything a
		// click there would act on.
		await page.mouse.click(2, 400);
		await expect(dropdown).toBeHidden();

		await toggle.click();
		await dropdown.getByRole("button", { name: "z.txt", exact: true }).click();
		await expect(dropdown).toBeHidden();
		await expect(page.locator("#file-1 .file-row")).toBeFocused();
		// Ride out the smooth scroll: the section ends up just below the
		// sticky toolbar.
		await expect
			.poll(async () => {
				const p = await placement("#file-1");
				return p !== null && p.below >= 0 && p.below <= 16;
			})
			.toBe(true);
		expect(await page.evaluate(() => history.length)).toBe(historyLength);

		await toggle.click();
		await dropdown.getByRole("checkbox", { name: /b\/z\.txt/ }).click();
		await expect(page.locator("#file-1")).toHaveCount(0);
		await dropdown.getByRole("button", { name: "z.txt", exact: true }).click();
		await expect(dropdown).toBeHidden();
		await expect(toggle).toBeFocused();
	} finally {
		await meerkat.kill();
	}
});

// Toolbar settings live in the config dir's settings.json. A change
// reaches the review's other tabs live over PubSub; another review runs
// in its own BEAM, so its tabs read the file when they load or rejoin.
// A rejoin without a reload, such as after a dropped socket, would also
// have LiveView's form recovery resubmit the page's stale ruler columns,
// saving them over the newer ones.
test("toolbar settings reach the review's other tabs live, and other reviews on load and rejoin", async ({
	page,
	context,
}) => {
	const meerkat = await startMeerkat();
	let second: Awaited<ReturnType<typeof startMeerkat>> | undefined;
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
		// LiveView doesn't patch a focused field, and mine stays focused.
		await mine.columns.fill("50");
		await expect(theirs.columns).toHaveValue("50");
		await theirs.openSettings();
		await theirs.columns.fill("60");
		await expect(mine.columns).toBeFocused();
		await expect(mine.columns).toHaveValue("60");

		second = await startMeerkat({ env: { XDG_CONFIG_HOME: configHome(meerkat.runsDir) } });
		const elsewhere = toolbar(await openJoined(context, second.url));
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
		const reopened = toolbar(await openJoined(context, second.url));
		await expect(reopened.columns).toHaveValue("70");
	} finally {
		await second?.kill();
		await meerkat.kill();
	}
});

// The HintDismiss hook keeps the dismissal in this browser's localStorage.
test("a dismissed line-comment hint stays hidden after a reload", async ({ page }) => {
	const meerkat = await startMeerkat();
	try {
		await page.goto(meerkat.url);
		await expect(page.locator("[data-phx-main]")).toHaveClass(/phx-connected/);
		const hint = page.locator("#meerkat-hint");
		await expect(hint).toBeVisible();
		await hint.locator(".hint-dismiss").click();
		await expect(hint).toBeHidden();
		await page.reload();
		await expect(page.locator("[data-phx-main]")).toHaveClass(/phx-connected/);
		await expect(hint).toBeHidden();
	} finally {
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

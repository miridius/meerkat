import { rmSync } from "node:fs";
import { createServer } from "node:net";
import type { BrowserContext, Page } from "@playwright/test";
import { makeFixture, manifestRoot, ownedTmpDir } from "./lib/fixture";
import { startMeerkats } from "./lib/runner";
import { afterNextFrame, expect, test } from "./lib/test";

// The browser seams of the review page around its diff: the scroll
// position a reload keeps, the sticky file header under a toolbar whose
// height changes, the line-comment hint's dismissal, the version chip's
// localStorage-backed badge and drop-down, and toolbar settings reaching
// other tabs. What the filter hides, pins and restores, what a dev and a
// prod build's chip render, and how settings parse and persist are covered
// by the LiveView tests.

const TALL_FILE = `${Array.from({ length: 400 }, (_, i) => `line ${i + 1}`).join("\n")}\n`;

const ONE_ROW_WIDTH = 1500;
const ONE_ROW_H = 41; // measured; not --toolbar-h's 40px fallback
// Narrow enough that the toolbar takes steps that change its height,
// such as moving Split / Unified and Wrap into the ⚙ popover, and
// wrapping.
const NARROW_WIDTHS = [900, 600, 320];

// A long branch name, with the toolbar still on one row at 1500px.
const LONG_BRANCH = "feature/request-timing-instrumentation-with-slow-route-alerts";

function reviewFixture() {
	const fixture = makeFixture({
		commitMsg: "Auto-approve a review nobody answers within 30 minutes\n\nBody paragraph.\n",
		files: { "lib/tall.ex": TALL_FILE, "lib/second.ex": TALL_FILE },
	});
	fixture.git("branch", "-m", LONG_BRANCH);
	return fixture;
}

type Probe = {
	toolbarH: number;
	headerTop: number;
	hitCheckbox: boolean;
	hitTag: string | null;
};

function probe(page: Page): Promise<Probe> {
	return page.evaluate(() => {
		const toolbar = document.querySelector(".diff-toolbar") as HTMLElement;
		const header = document.querySelector(".file-section-header") as HTMLElement;
		const box = header.getBoundingClientRect();
		const checkbox = header.querySelector('input[type="checkbox"]') as HTMLElement;
		const cb = checkbox.getBoundingClientRect();
		const onTop = document.elementFromPoint(cb.left + cb.width / 2, cb.top + cb.height / 2);
		return {
			toolbarH: Math.round(toolbar.getBoundingClientRect().height),
			headerTop: Math.round(box.top),
			hitCheckbox: onTop === checkbox,
			hitTag: onTop && `${onTop.tagName}.${onTop.className}`,
		};
	});
}

// The steps the toolbar has taken.
function squeezeSteps(page: Page) {
	return page
		.locator(".diff-toolbar")
		.evaluate((el) => (el.getAttribute("data-squeeze") ?? "").split(" ").filter(Boolean));
}

async function stepsAt(page: Page, width: number) {
	await page.setViewportSize({ width, height: 800 });
	await afterNextFrame(page);
	return squeezeSteps(page);
}

// Fitting the toolbar raises no errors, such as a ResizeObserver loop. They
// are kept outside the page, so a reload does not drop them.
async function trackPageErrors(page: Page) {
	const errors: string[] = [];
	await page.exposeFunction("reportPageError", (message: string) => errors.push(message));
	await page.addInitScript(() => {
		const w = window as unknown as { reportPageError(message: string): void };
		window.addEventListener("error", (e) => w.reportPageError(e.message));
	});
	return errors;
}

// The texts of the version chip's parts on screen; the ones a step takes
// off it are kept 1px wide for screen readers.
function chipOnScreen(page: Page) {
	return page
		.locator(".version-chip-btn")
		.evaluate((el) => [...el.children].filter((c) => c.getBoundingClientRect().width > 1).map((c) => c.textContent?.trim()));
}

// A loopback port no listener holds.
async function freePort(): Promise<number> {
	const server = createServer();
	await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
	const address = server.address();
	if (address === null || typeof address === "string") throw new Error("no port bound");
	await new Promise((resolve) => server.close(resolve));
	return address.port;
}

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

test("the page keeps its scroll on reload, pins each file header below the toolbar at any height, keeps a dismissed hint hidden, badges unseen versions, and shares toolbar settings with other tabs and reviews", async ({
	page,
	context,
}) => {
	// A dev build's version chip reads `dev: <branch>` for the meerkat
	// checkout, which would make the toolbar's width depend on that branch.
	// A baked manifest pins the chip to a 7-character commit, with eleven
	// updates after #10: a count of two digits, which must not narrow the
	// chip as it drops to none.
	const releaseRoot = manifestRoot([
		"abc1234567890",
		"https://github.com/miridius/meerkat",
		...Array.from({ length: 12 }, (_, i) => `Change ${21 - i} (#${21 - i})`),
	]);
	// The second review shares the first's config dir. Its tabs read the
	// settings when they load, so it can boot alongside the first.
	const configHome = ownedTmpDir("meerkat-e2e-config");
	// The launcher hands MEERKAT_PORT to the BEAM, which binds it while free.
	const port = await freePort();
	const [meerkat, second] = await startMeerkats(
		{
			fixture: reviewFixture(),
			// Without --port, so the BEAM picks its port.
			port: null,
			env: { RELEASE_ROOT: releaseRoot, XDG_CONFIG_HOME: configHome, MEERKAT_PORT: String(port) },
		},
		{ env: { XDG_CONFIG_HOME: configHome } },
	);
	try {
		expect(Number(new URL(meerkat.url).port), "the review binds the MEERKAT_PORT it was given").toBe(port);
		const errors = await trackPageErrors(page);
		const scrollY = () => page.evaluate(() => Math.round(window.scrollY));

		await test.step("the toolbar's height is right on the first paint, before any hook mounts", async () => {
			// Its own page: ./lib/test's `goto` waits for LiveView to join,
			// which cannot happen with the bundle blocked.
			const bare = await context.newPage();
			try {
				await bare.route("**/assets/app-*.js", (route) => route.abort());
				await bare.setViewportSize({ width: 900, height: 800 });
				await bare.goto(meerkat.url);
				await expect(bare.locator(".diff-toolbar")).toBeVisible();
				const published = await bare.evaluate(() => {
					const toolbar = document.querySelector(".diff-toolbar") as HTMLElement;
					return {
						toolbarH: Math.round(toolbar.getBoundingClientRect().height),
						published: document.documentElement.style.getPropertyValue("--toolbar-h").trim(),
						hookMounted: !!window.liveSocket,
						pillInView:
							(document.querySelector(".conn-indicator") as HTMLElement).getBoundingClientRect().right <=
							toolbar.getBoundingClientRect().right,
					};
				});
				expect(published.hookMounted, "the bundle that carries the Toolbar hook never loaded").toBe(false);
				expect(
					published.toolbarH,
					"before the hook runs the toolbar keeps to one row, the height the hook gives it at most widths",
				).toBe(ONE_ROW_H);
				expect(published.toolbarH, "the CSS fallback would be wrong").not.toBe(40);
				expect(published.pillInView, "the title and branch give up room, so the connection pill stays in view").toBe(true);
				expect(published.published, "--toolbar-h already carries the toolbar's real height").toBe(
					`${published.toolbarH}px`,
				);
			} finally {
				await bare.close();
			}
		});

		// A live-restart onto a version with changed assets makes
		// ReviewLive.mount/3 redirect on reconnect for a full page load. A
		// plain page.reload() reproduces that full reload (same origin, so
		// sessionStorage survives), which is the behaviour the
		// scroll-preservation code in app.js has to handle.
		await test.step("a fresh review starts at the top, spans the window, and a reload keeps its scroll", async () => {
			await page.setViewportSize({ width: 1920, height: 800 });
			await page.goto(meerkat.url);
			await expect(page.getByRole("button", { name: /tall\.ex/ })).toBeVisible();
			// No prior scroll was stashed for this origin, so the restore is a
			// no-op and the page stays at the top. A restore would run on the
			// next frame, the diff being tall enough by now.
			await afterNextFrame(page);
			expect(await scrollY()).toBe(0);
			// ReviewLive.mount/3 uses static_changed?/1 to redirect reconnecting
			// tabs with outdated assets for a full page load. That check uses
			// phx-track-static tags, so confirm those tags are present.
			expect(await page.locator("script[phx-track-static]").count()).toBeGreaterThan(0);

			// The BEAM port once shipped a 1400px max-width cap that wasted
			// roughly half a 1920px screen. Allow for the side padding on
			// `main.review`; the old cap was ~73% of the viewport.
			const main = await page.locator("main.review").evaluate((el) => ({
				computedMaxWidth: getComputedStyle(el).maxWidth,
				clientWidth: (el as HTMLElement).clientWidth,
				viewportWidth: window.innerWidth,
			}));
			expect(main.computedMaxWidth, "main.review has no max-width cap").toBe("none");
			expect(main.clientWidth).toBeGreaterThan(main.viewportWidth * 0.95);

			await page.evaluate(() => window.scrollTo(0, 1500));
			await expect.poll(scrollY).toBeGreaterThan(1000);
			const before = await scrollY();
			// Wait for the 200ms stash debounce to write to sessionStorage.
			await expect
				.poll(() => page.evaluate(() => Number(sessionStorage.getItem("meerkat:scrollY"))))
				.toBeGreaterThanOrEqual(before);
			await page.reload();
			await expect.poll(scrollY).toBeGreaterThan(before - 100);
		});

		await test.step(`the pinned file header sits below the toolbar at ${ONE_ROW_WIDTH}px and as narrowing to ${NARROW_WIDTHS.join("px and ")}px changes its height`, async () => {
			await page.setViewportSize({ width: ONE_ROW_WIDTH, height: 800 });
			await page.evaluate(() => window.scrollTo(0, 2500));
			await expect.poll(scrollY).toBeGreaterThan(2000);
			const wide = await probe(page);
			expect(
				wide.toolbarH,
				"the widest case under test is the unwrapped toolbar the old hardcoded offset was written for",
			).toBe(ONE_ROW_H);
			expect(
				wide.hitCheckbox,
				`the pinned header's approve checkbox is the topmost element at its own centre, not ${wide.hitTag}`,
			).toBe(true);
			expect(wide.headerTop, "the pinned file header sits directly below the toolbar").toBe(wide.toolbarH);

			for (const width of NARROW_WIDTHS) {
				await page.setViewportSize({ width, height: 800 });
				await expect
					.poll(async () => (await probe(page)).toolbarH, { message: `the toolbar's height changed at ${width}px` })
					.not.toBe(ONE_ROW_H);
				await afterNextFrame(page);
				const narrow = await probe(page);
				expect(narrow.headerTop, `at ${width}px the header follows the toolbar's new height without a reload`).toBe(
					narrow.toolbarH,
				);
				expect(
					narrow.hitCheckbox,
					`at ${width}px the approve checkbox is still the topmost element at its own centre, not ${narrow.hitTag}`,
				).toBe(true);
			}
		});

		// The HintDismiss hook keeps the dismissal in this browser's localStorage.
		await test.step("a dismissed line-comment hint stays hidden after a reload", async () => {
			const hint = page.locator("#meerkat-hint");
			await expect(hint).toBeVisible();
			await hint.locator(".hint-dismiss").click();
			await expect(hint).toBeHidden();
			await page.reload();
			await expect(hint).toBeHidden();
		});

		await test.step("the version chip's badge counts unseen updates, and at its step the chip shows only that count", async () => {
			await page.setViewportSize({ width: 2400, height: 800 });
			const wrap = page.locator(".version-chip-wrap");
			const chip = page.locator(".version-chip-btn");
			const badge = chip.locator(".version-badge");
			const popover = page.locator(".version-popover");
			const named = popover.locator(".version-popover-version");
			await expect(chip.locator(".chip-value")).toHaveText("abc1234");
			await expect(badge, "a first visit treats the current version as seen").toBeHidden();

			// Simulate having last acknowledged up to #10, then re-mount.
			await page.evaluate(() => localStorage.setItem("meerkat:lastSeenPr", "10"));
			await page.reload();
			await expect(badge).toHaveText("11");

			// With only its own step taken, the chip without its badge would fit
			// in full; while the drop-down is open it keeps its step all the same.
			let width = 2400;
			while ((await stepsAt(page, width)).length === 0) width -= 40;
			while ((await stepsAt(page, width)).length > 0) width += 1;
			width -= 1;
			expect(await stepsAt(page, width)).toEqual(["version"]);
			await chip.click();
			await expect(popover).toBeVisible();
			await expect(popover.getByRole("link", { name: /#11.*Change 11/ })).toHaveAttribute(
				"href",
				"https://github.com/miridius/meerkat/pull/11",
			);
			await afterNextFrame(page);
			expect(await squeezeSteps(page)).toEqual(["version"]);
			await expect(chip).toHaveCSS("opacity", "0");
			await chip.click();
			await expect(popover).toBeHidden();
			// Closed, opening the changelog having cleared the badge, it gives
			// the step back.
			await expect.poll(() => squeezeSteps(page)).toEqual([]);
			expect(await chipOnScreen(page), "the chip shows the version again").toEqual(["ver", "abc1234"]);
			await expect(chip, "focus stays on the chip that came back").toBeFocused();

			await page.evaluate(() => localStorage.setItem("meerkat:lastSeenPr", "10"));
			await page.reload();
			await expect(badge).toHaveText("11");
			// Past the version step, so the chip losing its badge cannot give it back.
			while (!(await stepsAt(page, width)).includes("conn")) width -= 20;
			expect(await chipOnScreen(page)).toEqual(["11"]);
			await expect(chip, "the version stays in the chip's name").toHaveAccessibleName(/abc1234/);

			// Opening it marks the updates seen, so the chip goes, keeping its box
			// so the drop-down stays where it opened.
			const box = await wrap.boundingBox();
			await chip.click();
			await expect(popover).toBeVisible();
			await expect(named).toHaveText(/^\s*meerkat\s+abc1234\s*$/);
			await expect(chip).toHaveCSS("opacity", "0");
			expect(await wrap.boundingBox()).toEqual(box);
			await expect(chip, "the count it keeps for its width is not read out").not.toHaveAccessibleName(/11/);
			// Clicking it again closes the drop-down, and the chip goes.
			await chip.click();
			await expect(popover).toBeHidden();
			await expect(wrap).toBeHidden();

			// Wrapped, the chip can sit near the window's left edge; the
			// drop-down still opens within the window.
			await page.evaluate(() => localStorage.setItem("meerkat:lastSeenPr", "10"));
			await page.setViewportSize({ width: 300, height: 800 });
			await page.reload();
			await expect(badge).toHaveText("11");
			// Opened from the keyboard, it keeps focus.
			await chip.focus();
			await page.keyboard.press("Enter");
			await expect(named).toBeVisible();
			await expect(chip).toBeFocused();
			const drop = await popover.evaluate((el) => el.getBoundingClientRect().toJSON());
			expect(drop.left).toBeGreaterThanOrEqual(0);
			expect(drop.right).toBeLessThanOrEqual(300);
			// Esc closes it too, and focus moves on from the chip as it goes.
			await page.keyboard.press("Escape");
			await expect(wrap).toBeHidden();
			// The view controls are in the ⚙ popover at this width, so ⚙ is next.
			await expect(page.locator(".toolbar-settings > summary")).toBeFocused();

			await stepsAt(page, 2400);
			expect(await chipOnScreen(page), "the chip shows the version again").toEqual(["ver", "abc1234"]);
			await chip.click();
			await expect(popover).toBeVisible();
			await expect(named, "with room, the chip itself names the version").toBeHidden();
			// Back under the chip, after the shift that kept it in the window.
			const [chipRight, dropRight] = await Promise.all(
				[wrap, popover].map((el) => el.evaluate((e) => e.getBoundingClientRect().right)),
			);
			expect(dropRight).toBeCloseTo(chipRight, 0);
			// Esc from one of its links gives focus back to the chip.
			await chip.focus();
			await page.keyboard.press("Tab");
			await expect(popover.getByRole("link").first()).toBeFocused();
			await page.keyboard.press("Escape");
			await expect(popover).toBeHidden();
			await expect(chip).toBeFocused();
			await chip.click();
			await expect(popover).toBeVisible();
			// A click elsewhere closes it, leaving focus where the click put it:
			// the files dropdown it opens takes focus to its filter box.
			const files = page.getByRole("button", { name: "Toggle file list" });
			await files.click();
			await expect(popover).toBeHidden();
			await afterNextFrame(page);
			await expect(page.getByRole("textbox", { name: "Filter files" })).toBeFocused();
			await files.click();
			await afterNextFrame(page);
			expect(errors, "no page errors").toEqual([]);
		});

		// Toolbar settings live in the config dir's settings.json. A change
		// reaches the review's other tabs live over PubSub; another review
		// runs in its own BEAM, so its tabs read the file when they load or
		// rejoin. A rejoin without a reload, such as after a dropped socket,
		// would also have LiveView's form recovery resubmit the page's stale
		// ruler columns, saving them over the newer ones.
		await test.step("toolbar settings reach the review's other tabs live, and other reviews on load and rejoin, each tab's change keeping the others'", async () => {
			const other = await openJoined(context, meerkat.url);
			const toolbar = (p: Page) => ({
				// The ⚙ popover holds a hidden second copy.
				wrap: p.locator(".diff-toolbar > .view-controls").getByLabel("Wrap"),
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
		});
	} finally {
		await second.kill();
		await meerkat.kill();
		rmSync(releaseRoot, { recursive: true, force: true });
		rmSync(configHome, { recursive: true, force: true });
	}
});

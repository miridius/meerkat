import { rmSync } from "node:fs";
import type { Page } from "@playwright/test";
import { SQUEEZE_STEPS } from "../../assets/ts/toolbarSqueeze";
import { makeFixture, makePrFixture, manifestRoot } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";
import { afterNextFrame, expect, test } from "./lib/test";

// The browser seam of the toolbar's squeeze steps: the Toolbar hook
// measuring the rendered toolbar and the CSS each step drives. Which steps,
// in which order, is unit-tested in assets/ts/toolbarSqueeze.test.ts.

// The steps the toolbar has taken, whether anything in it runs out of its
// box (past the toolbar, or past its item into the next), and whether it
// wraps onto a second row.
function toolbarState(page: Page) {
	return page.locator(".diff-toolbar").evaluate((el) => {
		const items = [...el.children].filter((c) => !c.matches(".toolbar-width") && c.getClientRects().length > 0);
		const firstBottom = Math.min(...items.map((c) => c.getBoundingClientRect().bottom));
		const outside = (inner: DOMRect, outer: DOMRect) => inner.left < outer.left - 1 || inner.right > outer.right + 1;
		const runsOut = items.some((item) => {
			const box = item.getBoundingClientRect();
			return [...item.querySelectorAll("*")].some(
				(d) => d.checkVisibility() && outside(d.getBoundingClientRect(), box),
			);
		});
		return {
			steps: (el.getAttribute("data-squeeze") ?? "").split(" ").filter(Boolean),
			overflows: el.scrollWidth > el.clientWidth || runsOut,
			wrapped: items.some((c) => c.getBoundingClientRect().top >= firstBottom),
		};
	});
}

async function at(page: Page, width: number) {
	await page.setViewportSize({ width, height: 800 });
	await afterNextFrame(page);
	return toolbarState(page);
}

// A dev build's version chip reads `dev: <branch>` for the meerkat
// checkout; a baked manifest pins it.
const MANIFEST = ["abc1234567890", "https://github.com/miridius/meerkat"];

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

// Whether the version chip shows the version rather than only its count.
function versionShown(page: Page) {
	return page
		.locator(".version-chip-btn")
		.evaluate((el) =>
			[...el.children].some(
				(c) => !c.matches(".version-badge") && c.getBoundingClientRect().width > 1 && c.textContent?.includes("abc1234"),
			),
		);
}

test("narrowing the window takes the squeeze steps in order, one row until the last, and the ⚙ popover then holds Split / Unified and Wrap", async ({
	page,
}) => {
	const releaseRoot = manifestRoot(MANIFEST);
	const fixture = makePrFixture({
		title: "Retire local review tooling for the manager plugin, keeping the review page as it was",
		baseRef: "release/2026-autumn-maintenance",
		headRef: "feature/request-timing-instrumentation-with-slow-route-alerts",
	});
	const meerkat = await startMeerkat({
		fixture,
		args: ["--pr", String(fixture.prNumber)],
		pathPrefixes: [fixture.ghStubDir],
		env: { RELEASE_ROOT: releaseRoot },
	});
	try {
		const errors = await trackPageErrors(page);
		await page.setViewportSize({ width: 2400, height: 800 });
		await page.goto(meerkat.url);
		await expect(page.locator(".diff-toolbar")).toHaveAttribute("data-squeeze", "");
		expect(await toolbarState(page)).toEqual({ steps: [], overflows: false, wrapped: false });
		// The ⚙ popover's copy of the view controls is in the page too, but
		// only one copy reaches screen readers and the Tab key.
		const oneViewControl = async () => {
			await expect(page.getByRole("checkbox", { name: "Wrap" })).toHaveCount(1);
			await expect(page.getByRole("button", { name: "Unified", exact: true })).toHaveCount(1);
		};
		await oneViewControl();

		const seen: string[] = [];
		let taken = 0;
		for (let width = 2400; width >= 280; width -= 20) {
			const state = await at(page, width);
			expect(state.steps, `at ${width}px the steps are the first few, in order`).toEqual(
				SQUEEZE_STEPS.slice(0, state.steps.length),
			);
			expect(state.steps.length, `at ${width}px no step is given back`).toBeGreaterThanOrEqual(taken);
			taken = state.steps.length;
			expect(state.overflows, `at ${width}px nothing runs past the toolbar`).toBe(false);
			expect(state.wrapped, `at ${width}px the toolbar wraps only as the last step`).toBe(
				state.steps.includes("wrap"),
			);
			for (const step of state.steps) if (!seen.includes(step)) seen.push(step);

			// Each part shows in full until its step, and is cut short by it.
			for (const [part, step] of [
				[".toolbar-title", "title"],
				[".branch-base", "base"],
				[".branch-head", "head"],
			]) {
				const text = await page
					.locator(part)
					.evaluate((el) => ({ shown: el.clientWidth, full: el.scrollWidth }));
				expect(text.shown, `at ${width}px some of ${part} shows`).toBeGreaterThan(30);
				if (!state.steps.includes(step)) {
					expect(text.shown, `at ${width}px ${part} shows in full before its step`).toBe(text.full);
				}
				if (state.steps.at(-1) === step) {
					expect(text.full, `at ${width}px its step cuts ${part} short`).toBeGreaterThan(text.shown);
				}
			}
			// The steps' other cuts: `☰ Files` to `☰`, and the connection
			// pill to its dot, its label kept for screen readers.
			const onScreen = (selector: string) =>
				page.locator(selector).evaluate((el) => el.checkVisibility() && el.getBoundingClientRect().width > 1);
			expect(await onScreen(".files-label"), `at ${width}px Files shows until its step`).toBe(
				!state.steps.includes("files"),
			);
			expect(await onScreen(".conn-label-connected"), `at ${width}px "connected" shows until its step`).toBe(
				!state.steps.includes("conn"),
			);
			await expect(page.locator(".conn-label-connected"), "screen readers still hear it").toBeVisible();
			// With no updates, the version step takes the chip away.
			const chipShown = await page.locator(".version-chip-btn").evaluate((el) => el.checkVisibility());
			expect(chipShown, `at ${width}px the version chip shows until its step`).toBe(
				!state.steps.includes("version"),
			);
			if (state.steps.length === 0) {
				const head = await page
					.locator(".branch-head")
					.evaluate((el) => ({ shown: el.clientWidth, full: el.scrollWidth }));
				expect(head.shown, `at ${width}px the head branch shows in full`).toBe(head.full);
			}
		}
		expect(seen, "every step was needed somewhere between 2400px and 280px").toEqual(SQUEEZE_STEPS);

		// Split / Unified and Wrap still work from the ⚙ popover.
		await at(page, 900);
		expect((await toolbarState(page)).steps).toContain("view");
		await expect(page.locator(".diff-toolbar > .view-controls .wrap-toggle")).toBeHidden();
		await expect(page.getByRole("checkbox", { name: "Wrap" })).toHaveCount(0);
		await page.locator(".toolbar-settings > summary").click();
		await oneViewControl();
		const popover = page.locator(".toolbar-settings-popover");
		// The re-render this click causes keeps the steps.
		await page.locator(".diff-toolbar").evaluate((el) => {
			const w = window as unknown as { squeezeDropped: boolean };
			w.squeezeDropped = false;
			// The hook never removes it, so a record of it being set where it
			// was absent means the patch dropped it.
			new MutationObserver((records) => {
				if (records.some((r) => r.oldValue === null)) w.squeezeDropped = true;
			}).observe(el, { attributeFilter: ["data-squeeze"], attributeOldValue: true });
		});
		await popover.getByRole("button", { name: "Unified", exact: true }).click();
		await expect(popover.getByRole("button", { name: "Unified", exact: true })).toHaveClass(/active/);
		await expect(page.locator(".file-section td.diff-line-new-num")).toHaveCount(0);
		await expect(popover).toBeVisible();
		expect(await page.evaluate(() => (window as unknown as { squeezeDropped: boolean }).squeezeDropped)).toBe(false);
		await page.locator(".toolbar-settings > summary").click();
		await expect(popover).toBeHidden();

		// A disconnect relabels the connection pill through a class on an
		// ancestor; at the narrowest width that does not yet take its step,
		// the longer label takes it.
		let width = 2400;
		while (!(await at(page, width)).steps.includes("conn")) width -= 20;
		while ((await at(page, width)).steps.includes("conn")) width += 1;
		expect((await toolbarState(page)).steps).toEqual(["version", "files"]);
		await page.evaluate(() => (window as unknown as { liveSocket: { disconnect(): void } }).liveSocket.disconnect());
		await expect(page.locator(".conn-label-error")).toBeVisible();
		await expect.poll(async () => (await toolbarState(page)).steps).toContain("conn");
		expect((await toolbarState(page)).overflows).toBe(false);
		// Rejoining in place, as after a BEAM restart, gives it back.
		await page.evaluate(() => (window as unknown as { liveSocket: { connect(): void } }).liveSocket.connect());
		await expect(page.locator("[data-phx-main].phx-connected")).toHaveCount(1);
		await expect.poll(async () => (await toolbarState(page)).steps).toEqual(["version", "files"]);
		expect((await toolbarState(page)).overflows).toBe(false);

		expect(errors, "no page errors").toEqual([]);
	} finally {
		await meerkat.kill();
		rmSync(releaseRoot, { recursive: true, force: true });
	}
});

test("at its step the version chip shows only its count of updates, and its drop-down names the version", async ({
	page,
}) => {
	// Eleven updates after #10: a count of two digits, which must not
	// narrow the chip as it drops to none.
	const releaseRoot = manifestRoot([
		...MANIFEST,
		...Array.from({ length: 12 }, (_, i) => `Change ${21 - i} (#${21 - i})`),
	]);
	const meerkat = await startMeerkat({
		fixture: makeFixture({ commitMsg: "Retire local review tooling\n", files: { "a.txt": "one\n" } }),
		env: { RELEASE_ROOT: releaseRoot },
	});
	try {
		const errors = await trackPageErrors(page);
		await page.setViewportSize({ width: 2400, height: 800 });
		await page.goto(meerkat.url);
		await page.evaluate(() => localStorage.setItem("meerkat:lastSeenPr", "10"));
		await page.reload();
		const wrap = page.locator(".version-chip-wrap");
		const chip = page.locator(".version-chip-btn");
		const popover = page.locator(".version-popover");
		const named = popover.locator(".version-popover-version");
		await expect(chip.locator(".version-badge")).toHaveText("11");

		// With only its own step taken, the chip without its badge would fit
		// in full; while the drop-down is open it keeps its step all the same.
		let width = 2400;
		while ((await at(page, width)).steps.length === 0) width -= 40;
		while ((await at(page, width)).steps.length > 0) width += 1;
		width -= 1;
		expect((await at(page, width)).steps).toEqual(["version"]);
		await chip.click();
		await expect(popover).toBeVisible();
		await afterNextFrame(page);
		expect((await toolbarState(page)).steps).toEqual(["version"]);
		await expect(chip).toHaveCSS("opacity", "0");
		await chip.click();
		await expect(popover).toBeHidden();
		// Closed, it gives the step back.
		await expect.poll(async () => (await toolbarState(page)).steps).toEqual([]);
		expect(await versionShown(page)).toBe(true);
		await expect(chip, "focus stays on the chip that came back").toBeFocused();

		await page.evaluate(() => localStorage.setItem("meerkat:lastSeenPr", "10"));
		await page.reload();
		await expect(chip.locator(".version-badge")).toHaveText("11");
		// Past the version step, so the chip losing its badge cannot give it back.
		while (!(await at(page, width)).steps.includes("conn")) width -= 20;
		const onScreen = await chip.evaluate((el) =>
			[...el.children].filter((c) => c.getBoundingClientRect().width > 1).map((c) => c.textContent),
		);
		expect(onScreen).toEqual(["11"]);
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
		await expect(chip.locator(".version-badge")).toHaveText("11");
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

		await at(page, 2400);
		expect(await versionShown(page)).toBe(true);
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
		// A click elsewhere closes it, leaving focus where the click put it.
		const files = page.getByRole("button", { name: "Toggle file list" });
		await files.click();
		await expect(popover).toBeHidden();
		await afterNextFrame(page);
		await expect(files).toBeFocused();
		await files.click();
		expect(errors, "no page errors").toEqual([]);
	} finally {
		await meerkat.kill();
		rmSync(releaseRoot, { recursive: true, force: true });
	}
});

test("the steps follow the toolbar's content at a fixed width, and a branch name shorter than the truncation floor keeps its own width", async ({
	page,
}) => {
	const releaseRoot = manifestRoot(MANIFEST);
	const fixture = makePrFixture({
		title: "Retire local review tooling for the manager plugin, keeping the review page as it was",
		headRef: "feature/request-timing-instrumentation-with-slow-route-alerts",
	});
	const meerkat = await startMeerkat({
		fixture,
		args: ["--pr", String(fixture.prNumber)],
		pathPrefixes: [fixture.ghStubDir],
		env: { RELEASE_ROOT: releaseRoot },
	});
	try {
		const errors = await trackPageErrors(page);
		await page.setViewportSize({ width: 2400, height: 800 });
		await page.goto(meerkat.url);
		await expect(page.locator(".diff-toolbar")).toHaveAttribute("data-squeeze", "");
		const base = page.locator(".branch-base");
		await expect(base).toHaveText("main");
		const natural = await base.evaluate((el) => el.getBoundingClientRect().width);

		// Collapsing a file adds `showing … of` and takes steps; expanding
		// it gives them back.
		const file = page.getByRole("button", { name: /feature\.rs/ });

		// The narrowest width that still takes no step.
		let width = 2400;
		while ((await at(page, width - 10)).steps.length === 0) width -= 10;
		await at(page, width);

		await file.click();
		await expect(page.locator(".toolbar-line-counts")).toContainText("showing");
		await expect.poll(async () => (await toolbarState(page)).steps.length).toBeGreaterThan(0);
		expect((await toolbarState(page)).overflows).toBe(false);

		// The counts' step drops `showing` and writes `/` for `of`.
		const counts = page.locator(".toolbar-line-counts");
		await expect(counts.locator(".counts-showing")).toBeVisible();
		let narrower = width;
		while (!(await at(page, narrower)).steps.includes("counts")) narrower -= 10;
		await expect(counts.locator(".counts-showing")).toBeHidden();
		await expect(counts.locator(".counts-of")).toBeHidden();
		await expect(counts.locator(".counts-slash")).toBeVisible();
		expect(await counts.evaluate((el) => el.innerText.replace(/\s+/g, " ").trim())).toMatch(
			/^\+\d+ -\d+ \/ \+\d+ -\d+$/,
		);
		await at(page, width);

		await file.click();
		await expect(page.locator(".toolbar-line-counts")).not.toContainText("showing");
		await expect.poll(async () => (await toolbarState(page)).steps).toEqual([]);

		// `main` is shorter than the floor, so it keeps its width while the
		// steps truncate the other branch.
		while (!(await at(page, width)).steps.includes("head")) width -= 20;
		expect(await base.evaluate((el) => el.getBoundingClientRect().width)).toBeCloseTo(natural, 0);
		expect(errors, "no page errors").toEqual([]);
	} finally {
		await meerkat.kill();
		rmSync(releaseRoot, { recursive: true, force: true });
	}
});

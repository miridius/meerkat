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
		const items = [...el.children].filter((c) => c.getClientRects().length > 0);
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
		await page.setViewportSize({ width: 2400, height: 800 });
		await page.goto(meerkat.url);
		await expect(page.locator(".diff-toolbar")).toHaveAttribute("data-squeeze", "");
		expect(await toolbarState(page)).toEqual({ steps: [], overflows: false, wrapped: false });

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

			if (state.steps.length === SQUEEZE_STEPS.indexOf("title") + 1) {
				const title = await page
					.locator(".toolbar-title")
					.evaluate((el) => ({ shown: el.clientWidth, full: el.scrollWidth }));
				expect(title.full, `at ${width}px the title is cut short`).toBeGreaterThan(title.shown);
			}
			for (const part of [".toolbar-title", ".branch-base", ".branch-head"]) {
				const shown = await page.locator(part).evaluate((el) => el.clientWidth);
				expect(shown, `at ${width}px some of ${part} shows`).toBeGreaterThan(30);
			}
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
		await page.locator(".toolbar-settings > summary").click();
		const popover = page.locator(".toolbar-settings-popover");
		await popover.getByRole("button", { name: "Unified", exact: true }).click();
		await expect(popover.getByRole("button", { name: "Unified", exact: true })).toHaveClass(/active/);
		await expect(page.locator(".file-section td.diff-line-new-num")).toHaveCount(0);
		await expect(popover).toBeVisible();
	} finally {
		await meerkat.kill();
		rmSync(releaseRoot, { recursive: true, force: true });
	}
});

test("at its step the version chip shows only its count of updates, and its drop-down names the version", async ({
	page,
}) => {
	const releaseRoot = manifestRoot([
		...MANIFEST,
		"Live-restart a review onto a newly-installed version (#11)",
		"Install versioned releases (#10)",
	]);
	const meerkat = await startMeerkat({
		fixture: makeFixture({ commitMsg: "Retire local review tooling\n", files: { "a.txt": "one\n" } }),
		env: { RELEASE_ROOT: releaseRoot },
	});
	try {
		await page.setViewportSize({ width: 2400, height: 800 });
		await page.goto(meerkat.url);
		await page.evaluate(() => localStorage.setItem("meerkat:lastSeenPr", "10"));
		await page.reload();
		const wrap = page.locator(".version-chip-wrap");
		const chip = page.locator(".version-chip-btn");
		const popover = page.locator(".version-popover");
		const named = popover.locator(".version-popover-version");
		await expect(chip.locator(".version-badge")).toHaveText("1");

		let width = 2400;
		// Past the version step, so the chip losing its badge cannot give it back.
		while (!(await at(page, width)).steps.includes("conn")) width -= 20;
		expect(await chip.evaluate((el) => el.innerText.trim())).toBe("1");

		// Opening it marks the update seen, so the chip goes; its drop-down stays.
		await chip.click();
		await expect(popover).toBeVisible();
		await expect(named).toHaveText(/^\s*meerkat\s+abc1234\s*$/);
		await expect(chip).toBeHidden();
		await page.keyboard.press("Escape");
		await expect(wrap).toBeHidden();

		await at(page, 2400);
		await expect(chip).toContainText("abc1234");
		await chip.click();
		await expect(popover).toBeVisible();
		await expect(named, "with room, the chip itself names the version").toBeHidden();
	} finally {
		await meerkat.kill();
		rmSync(releaseRoot, { recursive: true, force: true });
	}
});

test("a branch name shorter than the truncation floor keeps its own width", async ({ page }) => {
	const fixture = makePrFixture({
		title: "Retire local review tooling for the manager plugin, keeping the review page as it was",
		headRef: "feature/request-timing-instrumentation-with-slow-route-alerts",
	});
	const meerkat = await startMeerkat({
		fixture,
		args: ["--pr", String(fixture.prNumber)],
		pathPrefixes: [fixture.ghStubDir],
	});
	try {
		await page.setViewportSize({ width: 2400, height: 800 });
		await page.goto(meerkat.url);
		await expect(page.locator(".diff-toolbar")).toHaveAttribute("data-squeeze", "");
		const base = page.locator(".branch-base");
		await expect(base).toHaveText("main");
		const natural = await base.evaluate((el) => el.getBoundingClientRect().width);

		let width = 2400;
		while (!(await at(page, width)).steps.includes("head")) width -= 20;
		expect(await base.evaluate((el) => el.getBoundingClientRect().width)).toBeCloseTo(natural, 0);
	} finally {
		await meerkat.kill();
	}
});

test("the steps follow the toolbar's content at a fixed width: collapsing a file adds `showing … of` and takes steps, expanding it gives them back", async ({
	page,
}) => {
	const releaseRoot = manifestRoot(MANIFEST);
	const meerkat = await startMeerkat({
		fixture: makeFixture({
			commitMsg: "Retire local review tooling for the manager plugin\n",
			files: { "a.txt": "one\ntwo\n", "b.txt": "three\n" },
		}),
		env: { RELEASE_ROOT: releaseRoot },
	});
	try {
		await page.setViewportSize({ width: 2400, height: 800 });
		await page.goto(meerkat.url);
		await expect(page.locator(".diff-toolbar")).toHaveAttribute("data-squeeze", "");

		// The narrowest width that still takes no step.
		let width = 2400;
		while ((await at(page, width - 10)).steps.length === 0) width -= 10;
		await at(page, width);

		await page.getByRole("button", { name: /b\.txt/ }).click();
		await expect(page.locator(".toolbar-line-counts")).toContainText("showing");
		await expect.poll(async () => (await toolbarState(page)).steps.length).toBeGreaterThan(0);
		expect((await toolbarState(page)).overflows).toBe(false);

		await page.getByRole("button", { name: /b\.txt/ }).click();
		await expect(page.locator(".toolbar-line-counts")).not.toContainText("showing");
		await expect.poll(async () => (await toolbarState(page)).steps).toEqual([]);
	} finally {
		await meerkat.kill();
		rmSync(releaseRoot, { recursive: true, force: true });
	}
});

import { makeFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";
import { afterNextFrame, expect, test } from "./lib/test";

// The files dropdown's browser seams: it opens over the review from the
// sticky toolbar, below the toolbar even when it wraps, without moving the
// page or refitting the toolbar, and takes focus; Escape, an outside
// click, its title and a pick close it, a pick without refitting; a
// pick scrolls to the file without adding a history entry, which would
// stop window.close() closing the tab after a decision; and picking a
// hidden file moves focus to the button. Its tree draws its own
// scrollbars. Its tree, filters and events are covered by the LiveView
// tests.

// Playwright's headless Chromium hides every scrollbar unless told not to.
test.use({ launchOptions: { ignoreDefaultArgs: ["--hide-scrollbars"] } });

const TALL_FILE = `${Array.from({ length: 400 }, (_, i) => `line ${i + 1}`).join("\n")}\n`;

test("the files dropdown's tree draws a scrollbar each way it scrolls, and the dropdown opens over the review, closes on Escape, an outside click and a pick, and a pick adds no history entry", async ({
	page,
}) => {
	const files: Record<string, string> = {
		"a/tall.txt": TALL_FILE,
		"b/z.txt": TALL_FILE,
		[`${"long_name_".repeat(12)}.txt`]: "x\n",
	};
	for (let i = 10; i < 70; i++) files[`dir/file_${i}.txt`] = "x\n";
	const meerkat = await startMeerkat({ fixture: makeFixture({ files }) });
	try {
		const toggle = page.getByRole("button", { name: /^Toggle file list$/ });
		const dropdown = page.getByRole("dialog", { name: "Files" });
		const filter = page.getByRole("textbox", { name: "Filter files" });

		// macOS's default overlay scrollbars take no room and show only while
		// scrolling. The tree's styled scrollbar is always drawn, 10px wide,
		// where a classic one is 15px.
		await test.step("the tree draws a scrollbar each way it scrolls, and none when it fits; its rows span it and highlight on hover", async () => {
			await page.setViewportSize({ width: 700, height: 500 });
			await page.goto(meerkat.url);
			await toggle.click();
			const gutters = () =>
				page.locator(".file-tree-scroll").evaluate((el: HTMLElement) => ({
					vertical: el.offsetWidth - el.clientWidth,
					horizontal: el.offsetHeight - el.clientHeight,
				}));
			await expect.poll(gutters).toEqual({ vertical: 10, horizontal: 10 });

			// While the tree scrolls sideways, every row spans it, so the row
			// buttons keep to one column.
			const buttonRights = await page.locator(".file-entry").evaluateAll(
				(rows) =>
					new Set(
						rows.map((row) => Math.round([...row.querySelectorAll(".ghost-btn")].at(-1)?.getBoundingClientRect().right ?? 0)),
					).size,
			);
			expect(buttonRights).toBe(1);

			// A folder row highlights on hover with a file row's colour, which
			// the base button hover rule would otherwise overrule.
			const background = (el: Element) => getComputedStyle(el).backgroundColor;
			const file = page.locator(".file-entry").first();
			await file.hover();
			await expect.poll(() => file.evaluate(background)).not.toBe("rgba(0, 0, 0, 0)");
			await afterNextFrame(page);
			const highlight = await file.evaluate(background);
			const folder = page.locator(".tree-dir").first();
			await folder.hover();
			await expect.poll(() => folder.evaluate(background)).toBe(highlight);

			await filter.fill("file_42");
			await expect.poll(gutters).toEqual({ vertical: 0, horizontal: 0 });
			await filter.fill("");
			await page.keyboard.press("Escape");
			await expect(dropdown).toBeHidden();
		});

		await test.step("the dropdown opens over the review and closes without moving the page or refitting the toolbar", async () => {
			await page.setViewportSize({ width: 700, height: 720 });
			// The widest window in which the toolbar wraps onto a second row, its
			// last squeeze step.
			const toolbarHeight = () =>
				page.evaluate(() => document.querySelector(".diff-toolbar")?.getBoundingClientRect().height ?? 0);
			for (let width = 700; (await toolbarHeight()) <= 60; width -= 20) {
				await page.setViewportSize({ width, height: 720 });
				await afterNextFrame(page);
			}
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

			// Counts the toolbar's `data-squeeze` writes; every fit makes at
			// least one.
			const fits = () =>
				page.evaluate(() => {
					const w = window as unknown as { fitSteps?: number };
					if (w.fitSteps === undefined) {
						w.fitSteps = 0;
						new MutationObserver((records) => {
							w.fitSteps = (w.fitSteps ?? 0) + records.length;
						}).observe(document.querySelector(".diff-toolbar") as Element, { attributeFilter: ["data-squeeze"] });
					}
					return w.fitSteps;
				});

			await page.evaluate(() => window.scrollTo(0, 1500));
			await expect.poll(scrollY).toBeGreaterThan(1000);
			const scrolled = await scrollY();
			const fitsBefore = await fits();
			await toggle.click();
			await expect(dropdown).toBeVisible();
			await expect(filter).toBeFocused();
			const opened = await placement("#file-filter");
			expect(opened?.below).toBeGreaterThanOrEqual(0);
			expect(opened?.fits).toBe(true);
			expect(await scrollY(), "opening does not scroll the page").toBe(scrolled);
			await afterNextFrame(page);
			expect(await fits(), "opening does not refit the toolbar").toBe(fitsBefore);

			// Typing in the filter box leaves the dropdown open until Escape.
			await page.keyboard.press("z");
			await expect(dropdown).toContainText("Files (1 of 63)");
			await page.keyboard.press("Backspace");
			await expect(dropdown).toContainText("Files (63 of 63)");
			await page.keyboard.press("Escape");
			await expect(dropdown).toBeHidden();
			await expect(toggle).toBeFocused();

			// Opening at the very bottom of the page does not scroll it either.
			await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight));
			const bottom = await scrollY();
			await toggle.click();
			await expect(dropdown).toBeVisible();
			await afterNextFrame(page);
			expect(await scrollY(), "opening at the bottom does not scroll the page").toBe(bottom);
			await page.keyboard.press("Escape");
			await expect(dropdown).toBeHidden();

			await toggle.click();
			await expect(dropdown).toBeVisible();
			// The page's left margin, clear of the dropdown and of anything a
			// click there would act on.
			await page.mouse.click(2, 400);
			await expect(dropdown).toBeHidden();

			// Its title button closes it too, handing focus back.
			await toggle.click();
			await dropdown.getByRole("button", { name: "Files (63 of 63)" }).focus();
			await page.keyboard.press("Enter");
			await expect(dropdown).toBeHidden();
			await expect(toggle).toBeFocused();

			await toggle.click();
			await expect(dropdown).toBeVisible();
			await afterNextFrame(page);
			const fitsBeforePick = await fits();
			await dropdown.getByRole("button", { name: "z.txt", exact: true }).click();
			await expect(dropdown).toBeHidden();
			await expect(page.locator("#file-1 .file-row")).toBeFocused();
			await afterNextFrame(page);
			expect(await fits(), "closing on a pick does not refit the toolbar").toBe(fitsBeforePick);
			// Ride out the smooth scroll: the file's header ends up where it
			// sticks, just below the sticky toolbar.
			await expect
				.poll(async () => {
					const p = await placement("#file-1 .file-section-header");
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

			// In a phone-width window it stays inside the toolbar, which would
			// otherwise count it as overflow and squeeze on every fit.
			await page.setViewportSize({ width: 300, height: 720 });
			await toggle.click();
			await expect(dropdown).toBeVisible();
			const overhang = await page.evaluate(() => {
				const el = document.querySelector("#file-filter")?.getBoundingClientRect();
				const bar = document.querySelector(".diff-toolbar")?.getBoundingClientRect();
				return el && bar ? Math.round(el.right - bar.right) : null;
			});
			expect(overhang).toBeLessThan(0);
		});
	} finally {
		await meerkat.kill();
	}
});

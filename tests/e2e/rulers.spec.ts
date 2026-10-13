import { writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Locator, Page } from "@playwright/test";
import { makeFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";
import { afterNextFrame, expect, test } from "./lib/test";

// The browser seam of the ruler setting: DiffViewer.svelte measures each
// side's visible code width to choose which rulers to draw, and the
// suggestion editor redraws its rulers when the setting changes. Parsing
// and persisting the setting are covered by the LiveView tests.

const LONG = `${"x".repeat(130)}\n`;

// A modified file, so the diff can show Split view.
function wideFixture() {
	const fixture = makeFixture({ files: { "wide.txt": `short\n${LONG}` } });
	fixture.git("commit", "-q", "-m", "base");
	writeFileSync(join(fixture.dir, "wide.txt"), `shorter\n${LONG}${LONG}`);
	fixture.git("add", "wide.txt");
	return fixture;
}

// The rulers a code cell draws: the columns in its ruler variable.
async function rulersOn(cell: Locator): Promise<string[]> {
	return cell.evaluate((td) => {
		const side = td.classList.contains("diff-line-old-content")
			? "old"
			: td.classList.contains("diff-line-new-content")
				? "new"
				: "unified";
		const value = getComputedStyle(td).getPropertyValue(`--meerkat-rulers-${side}`);
		return [...value.matchAll(/transparent calc\(2em \+ (\d+)ch\),/g)].map((m) => m[1]);
	});
}

async function openSettings(page: Page) {
	const summary = page.locator(".toolbar-settings > summary");
	if ((await page.locator(".toolbar-settings[open]").count()) === 0) await summary.click();
}

test("diff rulers show only where the visible code column fits them and follow the ⚙ setting", async ({
	page,
}) => {
	const meerkat = await startMeerkat({ fixture: wideFixture() });
	try {
		await page.setViewportSize({ width: 2000, height: 800 });
		await page.goto(meerkat.url);
		const file = page.locator(".file-section").filter({ hasText: "wide.txt" });
		const oldCell = file.locator("td.diff-line-old-content").first();
		const newCell = file.locator("td.diff-line-new-content").first();
		await expect(newCell).toBeVisible();

		// Wide enough for both on each side of Split view.
		await expect.poll(() => rulersOn(oldCell)).toEqual(["80", "110"]);
		await expect.poll(() => rulersOn(newCell)).toEqual(["80", "110"]);

		// Split view's halves are equally wide, so at every width each
		// draws the same rulers; 10px steps cross each ruler's threshold.
		for (let width = 1300; width <= 2000; width += 10) {
			await page.setViewportSize({ width, height: 800 });
			await afterNextFrame(page);
			expect(await rulersOn(newCell), `at ${width}px`).toEqual(await rulersOn(oldCell));
		}

		// Each half of a 1000px page is too narrow for either.
		await page.setViewportSize({ width: 1000, height: 800 });
		await afterNextFrame(page);
		await expect.poll(() => rulersOn(newCell)).toEqual([]);

		// Unified view's one code column fits 80 but not 110, with wrap on
		// or off; with wrap off the long lines widen the cell past the view.
		await page.getByRole("button", { name: /^Unified$/ }).click();
		const unifiedCell = file.locator("td.diff-line-content").first();
		await expect.poll(() => rulersOn(unifiedCell)).toEqual(["80"]);
		await page.getByLabel("Wrap").click();
		await expect(page.getByLabel("Wrap")).not.toBeChecked();
		await afterNextFrame(page);
		await expect.poll(() => rulersOn(file.locator("td.diff-line-content").first())).toEqual(["80"]);

		// The ⚙ popover hides them, and sets their columns.
		await openSettings(page);
		const toggle = page.getByLabel("Rulers", { exact: true });
		await toggle.click();
		await expect.poll(() => rulersOn(file.locator("td.diff-line-content").first())).toEqual([]);
		// The re-render a setting change causes leaves the popover open.
		await expect(page.locator(".toolbar-settings-popover")).toBeVisible();
		await toggle.click();
		const columns = page.getByLabel("Ruler columns");
		await columns.fill("40, 120");
		await expect.poll(() => rulersOn(file.locator("td.diff-line-content").first())).toEqual(["40"]);

		// The setting survives a reload.
		await page.reload();
		await expect.poll(() => rulersOn(file.locator("td.diff-line-content").first())).toEqual(["40"]);
		await openSettings(page);
		await expect(page.getByLabel("Ruler columns")).toHaveValue("40, 120");
	} finally {
		await meerkat.kill();
	}
});

test("two tabs changing different settings keep both", async ({ page, context }) => {
	const meerkat = await startMeerkat({ fixture: wideFixture() });
	try {
		await page.goto(meerkat.url);
		const other = await context.newPage();
		await other.goto(meerkat.url);

		await openSettings(page);
		await page.getByLabel("Ruler columns").fill("72");
		await expect(page.getByLabel("Ruler columns")).toHaveAttribute("value", "72");
		await openSettings(other);
		await other.getByRole("button", { name: /^8$/ }).click();
		await expect(other.getByRole("button", { name: /^8$/ })).toHaveClass(/active/);

		for (const tab of [page, other]) {
			await tab.bringToFront();
			await tab.reload();
			await openSettings(tab);
			await expect(tab.getByLabel("Ruler columns")).toHaveValue("72");
			await expect(tab.getByRole("button", { name: /^8$/ })).toHaveClass(/active/);
		}
	} finally {
		await meerkat.kill();
	}
});

test("an open suggestion editor redraws its rulers when the setting changes", async ({ page }) => {
	const meerkat = await startMeerkat({ fixture: wideFixture() });	try {
		await page.goto(meerkat.url);
		const file = page.locator(".file-section").filter({ hasText: "wide.txt" });
		await file.locator('td.diff-line-new-num:has(span[data-line-num="2"])').click();
		const form = file.locator("tr.meerkat-form-row .comment-form");
		await form.getByRole("button", { name: /^Suggestion$/ }).click();
		const content = form.locator(".code-host .cm-content");
		await expect(content).toBeVisible();
		const gradients = () =>
			content.evaluate((el) => getComputedStyle(el).backgroundImage.split("linear-gradient").length - 1);
		await expect.poll(gradients).toBe(2);

		await openSettings(page);
		await page.getByLabel("Ruler columns").fill("72");
		await expect.poll(gradients).toBe(1);
		await page.getByLabel("Rulers", { exact: true }).click();
		await expect.poll(gradients).toBe(0);
	} finally {
		await meerkat.kill();
	}
});

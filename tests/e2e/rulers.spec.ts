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

const BLOCK = "moved one\nmoved two\nmoved three\n";
const STAYS = "stays one\nstays two\nstays three\nstays four\nstays five\n";

// A modified file, so the diff can show Split view, and a file whose
// block moves, so its lines get the moved-line tint.
function wideFixture() {
	const fixture = makeFixture({
		files: { "wide.txt": `short\n${LONG}`, "moved.txt": `${BLOCK}${STAYS}` },
	});
	fixture.git("commit", "-q", "-m", "base");
	writeFileSync(join(fixture.dir, "wide.txt"), `shorter\n${LONG}${LONG}`);
	writeFileSync(join(fixture.dir, "moved.txt"), `${STAYS}${BLOCK}`);
	fixture.git("add", "wide.txt", "moved.txt");
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

// The rulers a code cell draws in its right padding, past where its
// text wraps.
async function rulersPastText(cell: Locator): Promise<number[]> {
	const columns = (await rulersOn(cell)).map(Number);
	return cell.evaluate((td, columns) => {
		const probe = document.createElement("span");
		probe.style.cssText = "position: absolute; visibility: hidden; width: 100ch";
		td.append(probe);
		const ch = probe.getBoundingClientRect().width / 100;
		probe.style.width = "2em";
		const offset = probe.getBoundingClientRect().width;
		probe.remove();
		const textRight = td.getBoundingClientRect().width - Number.parseFloat(getComputedStyle(td).paddingRight);
		return columns.filter((n) => offset + n * ch > textRight);
	}, columns);
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

		// A moved line's tint keeps its rulers.
		const movedCell = page.locator(".file-section").filter({ hasText: "moved.txt" }).locator("td.moved-line").first();
		await expect(movedCell).toBeVisible();
		await expect
			.poll(() => movedCell.evaluate((td) => getComputedStyle(td).backgroundImage.split("linear-gradient").length - 1))
			.toBe(3);

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
		// Around the width where 110 starts to fit, it is never drawn in
		// the cell's right padding.
		let crossed = false;
		for (let width = 1005; width <= 1050; width += 1) {
			await page.setViewportSize({ width, height: 800 });
			await afterNextFrame(page);
			expect(await rulersPastText(unifiedCell), `at ${width}px`).toEqual([]);
			crossed ||= (await rulersOn(unifiedCell)).includes("110");
		}
		expect(crossed, "the sweep reaches the width where 110 fits").toBe(true);
		await page.setViewportSize({ width: 1000, height: 800 });
		await afterNextFrame(page);
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

		// Rows being drag-selected keep their rulers.
		await page.locator(".toolbar-settings > summary").click();
		await file.locator('td.diff-line-num span[data-line-new-num="2"]').hover();
		await page.mouse.down();
		await file.locator('td.diff-line-num span[data-line-new-num="3"]').hover();
		const dragged = file.locator("tr.diff-line.drag-selecting > td.diff-line-content").first();
		await expect(dragged).toHaveCSS("background-color", "rgba(31, 111, 235, 0.32)");
		await expect(dragged).toHaveCSS("background-image", /linear-gradient/);
		await page.mouse.up();
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
	const meerkat = await startMeerkat({ fixture: wideFixture() });
	try {
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

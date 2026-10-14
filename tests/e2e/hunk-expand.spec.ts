import { writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Locator, Page } from "@playwright/test";
import { afterNextFrame, expect, test } from "./lib/test";
import { startMeerkat } from "./lib/runner";
import { makeFixture } from "./lib/fixture";

// The 80-line fixture edits lines 20 and 60, leaving hidden lines
// above the first hunk, in the 33-line gap between hunks, and below
// the second, so every hunk row has an expand button.
function twoHunkFixture() {
	const lines = (edit: boolean) =>
		Array.from({ length: 80 }, (_, i) => {
			const n = i + 1;
			if (edit && n === 20) return "line twenty";
			if (edit && n === 60) return "line sixty";
			return `line ${n}`;
		}).join("\n") + "\n";
	const fixture = makeFixture({ files: { "a.txt": lines(false) } });
	fixture.git("commit", "-q", "-m", "base");
	writeFileSync(join(fixture.dir, "a.txt"), lines(true));
	fixture.git("add", "a.txt");
	return fixture;
}

async function newGutterSpan(file: Locator): Promise<{ left: number; right: number }> {
	const box = await file.locator("td.diff-line-new-num").first().boundingBox();
	if (!box) throw new Error("new-side gutter cell has no box");
	return { left: box.x, right: box.x + box.width };
}

function expandButtons(file: Locator): Locator {
	return file.locator('td.diff-line-hunk-action button[title^="Expand"]').filter({ visible: true });
}

// In split mode, the expand buttons sit in the right-hand gutter only, the
// header shows once beside them, and Expand All shows the hidden lines.
async function checkSplit(page: Page, file: Locator): Promise<void> {
	// The three visible buttons are Expand Up on the first hunk, Expand All
	// between hunks, and Expand Down after the last. The 33-line gap is
	// shorter than @git-diff-view's composeLen (40), so it offers a single
	// Expand All button.
	const visible = expandButtons(file);
	await expect(visible).toHaveCount(3);

	const gutter = await newGutterSpan(file);
	for (const button of await visible.all()) {
		const box = await button.boundingBox();
		if (!box) throw new Error("visible expand button has no box");
		const centre = box.x + box.width / 2;
		expect(centre).toBeGreaterThanOrEqual(gutter.left);
		expect(centre).toBeLessThanOrEqual(gutter.right);
	}

	// The emptied old-side action cell should match the hunk header background,
	// rather than look like a blank button tile, while the right-hand cell
	// holding the buttons keeps its tile colour.
	const leftAction = file.locator("td.diff-line-hunk-action").first();
	const leftHeader = file.locator("td.diff-line-hunk-content").first();
	const rightAction = file
		.locator("td.diff-line-hunk-action")
		.filter({ has: page.locator('button[title^="Expand"]').filter({ visible: true }) })
		.first();
	const bg = (cell: Locator) => cell.evaluate((el) => getComputedStyle(el).backgroundColor);
	expect(await bg(leftAction)).toBe(await bg(leftHeader));
	expect(await bg(rightAction)).not.toBe(await bg(leftHeader));

	// Each hunk header should appear once, not once per side, on the
	// right beside its expand button.
	const header = file.getByText(/^@@ -17,7 \+17,7 @@$/).filter({ visible: true });
	await expect(header).toHaveCount(1);
	const headerBox = await header.boundingBox();
	if (!headerBox) throw new Error("hunk header has no box");
	expect(headerBox.x).toBeGreaterThanOrEqual(gutter.right);

	await expect(file.getByText("line 40", { exact: true }).first()).toBeHidden();
	await file.locator('button[title="Expand All"]').filter({ visible: true }).click();
	await expect(file.getByText("line 40", { exact: true }).first()).toBeVisible();
}

test("hunk expand buttons stay in the single unified gutter, and in split mode, wrapped or not, sit in the right-hand gutter only and expand the hidden lines", async ({
	page,
}) => {
	const meerkat = await startMeerkat({ fixture: twoHunkFixture() });
	try {
		await page.goto(meerkat.url);
		const file = page.locator(".file-section").filter({ hasText: "a.txt" });
		const wrapToggle = page.locator(".diff-toolbar > .view-controls .wrap-toggle input[type=checkbox]");

		await page.getByRole("button", { name: /^Unified$/ }).click();
		await expect(file.locator("td.diff-line-new-num")).toHaveCount(0);
		const unified = expandButtons(file);
		await expect(unified).toHaveCount(3);
		const gutter = await file.locator("td.diff-line-num").first().boundingBox();
		if (!gutter) throw new Error("unified gutter cell has no box");
		for (const button of await unified.all()) {
			const box = await button.boundingBox();
			if (!box) throw new Error("visible expand button has no box");
			expect(box.x).toBeGreaterThanOrEqual(gutter.x - 1);
			expect(box.x + box.width).toBeLessThanOrEqual(gutter.x + gutter.width + 1);
		}

		await page.getByRole("button", { name: /^Split$/ }).click();
		await expect(file.locator("td.diff-line-new-num").first()).toBeVisible();
		await expect(wrapToggle).toBeChecked();
		await checkSplit(page, file);

		// A reload collapses what was expanded, so the wrap-off table starts
		// with every line hidden again.
		await page.reload();
		await expect(wrapToggle).toBeChecked();
		await wrapToggle.uncheck();
		// The toggle round-trips through the server before the diff swaps
		// tables, so wait for the wrap-off table, whose hunk rows carry
		// data-side, before measuring anything in it.
		await expect(file.locator('tr.diff-line-hunk[data-side="new"]').first()).toBeAttached();
		await checkSplit(page, file);
	} finally {
		await meerkat.kill();
	}
});

// A 1200-line file with a line changed every 30 lines, so the diff has 40
// hunks.
function manyHunkFixture() {
	const lines = (edit: boolean) =>
		`${Array.from({ length: 1200 }, (_, i) => {
			const n = i + 1;
			return edit && n % 30 === 0 ? `changed line ${n}` : `line ${n}`;
		}).join("\n")}\n`;
	const fixture = makeFixture({ files: { "many.txt": lines(false) } });
	fixture.git("commit", "-q", "-m", "base");
	writeFileSync(join(fixture.dir, "many.txt"), lines(true));
	fixture.git("add", "many.txt");
	return fixture;
}

// With Wrap off, Split view draws each side in its own table. Lists the
// rows, by `data-line`, whose top differs from the other side's row, or a
// single entry giving the row counts when a side has none or they differ.
function misalignedRows(file: Locator): Promise<string[]> {
	return file.evaluate((section) => {
		const tops = (side: string) =>
			new Map(
				Array.from(section.querySelectorAll<HTMLElement>(`table.${side}-diff-table > tbody > tr[data-line]`), (tr) => [
					tr.dataset.line,
					tr.getBoundingClientRect().top,
				]),
			);
		const oldTops = tops("old");
		const newTops = tops("new");
		if (oldTops.size === 0 || oldTops.size !== newTops.size) return [`old ${oldTops.size} rows, new ${newTops.size}`];
		return Array.from(oldTops).flatMap(([line, top]) => {
			const other = newTops.get(line);
			return other !== undefined && Math.abs(other - top) < 0.5 ? [] : [`${line}: ${top} vs ${other}`];
		});
	});
}

test("in Split view with Wrap off, an expand lays the diff out a few times, not once per hunk, and the two sides' rows stay level", async ({
	page,
}) => {
	const meerkat = await startMeerkat({ fixture: manyHunkFixture() });
	try {
		await page.goto(meerkat.url);
		const file = page.locator(".file-section").filter({ hasText: "many.txt" });
		await page.getByRole("button", { name: /^Split$/ }).click();
		await page.locator(".diff-toolbar .wrap-toggle input[type=checkbox]").uncheck();
		await expect(file.locator('tr.diff-line-hunk[data-side="new"]').first()).toBeAttached();
		await afterNextFrame(page);
		expect(await misalignedRows(file)).toEqual([]);

		// The rows after the expanded lines each hold a hunk whose height
		// @git-diff-view syncs across the two tables. Done row by row as
		// Svelte re-renders the rows, each sync laid out both tables again.
		const cdp = await page.context().newCDPSession(page);
		const events: { name: string; ph: string }[] = [];
		cdp.on("Tracing.dataCollected", (data) => events.push(...(data.value as { name: string; ph: string }[])));
		const traced = new Promise((resolve) => cdp.once("Tracing.tracingComplete", resolve));
		await cdp.send("Tracing.start", { categories: "devtools.timeline", transferMode: "ReportEvents" });
		await expandButtons(file).nth(1).click();
		await expect(file.getByText("line 40", { exact: true }).first()).toBeVisible();
		await afterNextFrame(page);
		await cdp.send("Tracing.end");
		await traced;
		const layouts = events.filter((e) => e.name === "Layout" && e.ph === "X").length;
		// 3-4 with the fix, about 90 without it.
		expect(layouts).toBeGreaterThan(0);
		expect(layouts).toBeLessThan(8);
		expect(await misalignedRows(file)).toEqual([]);

		// A font size change resizes every row in place, without a
		// re-render. Both sides' rows here are the same natural height, so
		// this guards against a sync writing a wrong height.
		await page.locator(".toolbar-settings > summary").click();
		await page.getByLabel("Increase font size").click();
		await page.getByLabel("Increase font size").click();
		await expect(page.locator(".toolbar-settings .toolbar-value").first()).toHaveText("15px");
		await afterNextFrame(page);
		await expect.poll(() => misalignedRows(file)).toEqual([]);
	} finally {
		await meerkat.kill();
	}
});

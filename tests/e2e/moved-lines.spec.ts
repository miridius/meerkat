import { writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Locator } from "@playwright/test";
import { makeFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";
import { expect, test } from "./lib/test";

// The browser seam of moved-code highlighting: DiffViewer.svelte tints
// a moved block's rows and puts an icon linking to its counterpart in
// the first row's gutter, in a table @git-diff-view re-renders. Finding
// the moves is covered by the Meerkat.Moves tests.

const helper = (n: number) =>
	`export function helper${n}(input: string, options: { locale: string; strict: boolean }): string {
  const trimmed${n} = input.trim().toLowerCase();
  return trimmed${n}.slice(0, ${n});
}
`;

// helper2 moves to the end of the file, leaving collapsed context above
// and between the hunks. It and its blank line are lines 6-10, and land
// on lines 55-59 with the blank first.
// `wide` ends helper1's first line in a comment wider than any window.
function movedBlockFixture({ wide = false } = {}) {
	const helpers = Array.from({ length: 12 }, (_, i) => helper(i + 1));
	if (wide) helpers[0] = helpers[0].replace("{\n", `{ // ${"wide ".repeat(100)}\n`);
	const fixture = makeFixture({ files: { "util.ts": helpers.join("\n") } });
	fixture.git("commit", "-q", "-m", "base");
	const [moved] = helpers.splice(1, 1);
	writeFileSync(join(fixture.dir, "util.ts"), [...helpers, moved].join("\n"));
	fixture.git("add", "util.ts");
	return fixture;
}

const MOVED = [
	...[55, 56, 57, 58, 59].map((n) => `new:${n}`),
	...[6, 7, 8, 9, 10].map((n) => `old:${n}`),
].sort();
const EXPECTED = { tinted: MOVED, links: ["new:55", "old:6"], drawn: true };
const PAIR_0_TINT = "rgba(96, 165, 250, 0.18)";
const FLASH = "rgba(88, 166, 255, 0.35)";

// The `side:line` of each tinted code cell and of each link's row, and
// whether each tinted cell draws the tint.
function movedState(file: Locator) {
	return file.evaluate((root, tint) => {
		const lineOf = (tr: Element, side: string) =>
			tr.querySelector(`td.diff-line-${side}-num [data-line-num]`)?.getAttribute("data-line-num") ||
			tr.querySelector(`[data-line-${side}-num]`)?.getAttribute(`data-line-${side}-num`);
		const where = (td: Element) => {
			const tr = td.closest("tr") as Element;
			const side = /diff-line-new-(content|num)/.test(td.className)
				? "new"
				: /diff-line-old-(content|num)/.test(td.className) || !lineOf(tr, "new")
					? "old"
					: "new";
			return `${side}:${lineOf(tr, side)}`;
		};
		const cells = Array.from(root.querySelectorAll("td.moved-line"));
		return {
			tinted: cells.map(where).sort(),
			links: Array.from(root.querySelectorAll(".moved-badge"), (b) => where(b.closest("td") as Element)).sort(),
			drawn: cells.every((td) => getComputedStyle(td).backgroundImage.includes(tint)),
		};
	}, PAIR_0_TINT);
}

// Clicks the old block's link, and returns the box-shadow its
// counterpart's first code cell draws in the same task: the flash,
// which lasts only 1.6s, starts synchronously with the click.
function flashOnClick(file: Locator) {
	return file.evaluate((root) => {
		(root.querySelector(".moved-badge") as HTMLElement).click();
		const tr = root.querySelector(
			'tr.diff-line:has(td.diff-line-new-num [data-line-num="56"], [data-line-new-num="56"])',
		) as Element;
		const td = tr.querySelector("td.diff-line-new-content, td.diff-line-content") as Element;
		return getComputedStyle(td).boxShadow;
	});
}

// Clicks the old block's link, then a visible Expand button in the same
// task, and returns the line numbers of the cells still flashing two
// frames later, well inside the 1.6s flash.
function expandDuringFlash(file: Locator) {
	return file.evaluate(async (root) => {
		(root.querySelector(".moved-badge") as HTMLElement).click();
		const expand = Array.from(
			root.querySelectorAll<HTMLElement>('td.diff-line-hunk-action button[title^="Expand"]'),
		).find((b) => b.checkVisibility());
		(expand as HTMLElement).click();
		await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
		return Array.from(root.querySelectorAll("td"))
			.filter((td) => td.getAnimations().length > 0)
			.map((td) => td.closest("tr")?.querySelector("[data-line-num]")?.getAttribute("data-line-num"));
	});
}

// Each line number that runs into its gutter cell's right padding.
function crampedNumbers(file: Locator) {
	return file.evaluate((root) =>
		Array.from(root.querySelectorAll("td.diff-line-old-num, td.diff-line-new-num, td.diff-line-num")).flatMap(
			(td) => {
				const limit = td.getBoundingClientRect().right - Number.parseFloat(getComputedStyle(td).paddingRight);
				return Array.from(td.querySelectorAll("span"))
					.filter((s) => s.textContent?.trim() && s.getBoundingClientRect().right > limit + 0.5)
					.map((s) => s.textContent?.trim());
			},
		),
	);
}

// Each icon's text, unless it sits in a line-number gutter cell, inside
// the visible part of its scroll pane, and clear of every line number
// and every character of code.
function misplacedIcons(file: Locator) {
	return file.evaluate((root) => {
		const range = document.createRange();
		const textBoxes = (el: Element) => {
			const boxes: DOMRect[] = [];
			const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
			for (let n = walker.nextNode(); n; n = walker.nextNode()) {
				if (n.parentElement?.closest(".moved-badge")) continue;
				for (let i = 0; i < (n.textContent ?? "").length; i++) {
					range.setStart(n, i);
					range.setEnd(n, i + 1);
					const r = range.getBoundingClientRect();
					if (r.width > 0) boxes.push(r);
				}
			}
			return boxes;
		};
		return Array.from(root.querySelectorAll(".moved-badge")).flatMap((icon) => {
			const b = icon.getBoundingClientRect();
			const td = icon.closest("td") as Element;
			const pane = (icon.closest(".diff-table-scroll-container") ?? root).getBoundingClientRect();
			const inGutter = /diff-line-(old-|new-)?num/.test(td.className);
			const inPane = b.left >= pane.left && b.right <= pane.right;
			const hit = textBoxes(td.closest("tr") as Element).some(
				(r) => r.right > b.left && r.left < b.right && r.bottom > b.top && r.top < b.bottom,
			);
			return inGutter && inPane && !hit ? [] : [`${icon.getAttribute("title")}: ${JSON.stringify({ inGutter, inPane, hit })}`];
		});
	});
}

test("moved lines keep their tint and links when a collapsed section expands or the view changes, and a link flashes its counterpart", async ({
	page,
}) => {
	const meerkat = await startMeerkat({ fixture: movedBlockFixture() });
	try {
		await page.goto(meerkat.url);
		const file = page.locator(".file-section").filter({ hasText: "util.ts" });
		await expect.poll(() => movedState(file)).toEqual(EXPECTED);

		expect(await flashOnClick(file)).toContain(FLASH);

		// Expanding inserts rows above the moved ones; @git-diff-view reuses
		// the existing row elements for the lines that shift into them.
		const expand = file.locator('td.diff-line-hunk-action button[title^="Expand"]').filter({ visible: true });
		await expand.first().click();
		await expect.poll(() => movedState(file)).toEqual(EXPECTED);

		// Each toggle round-trips through the server before the table is
		// replaced, so wait for the new table, or the poll reads the old one.
		// Split view without wrap is two tables of rows, replacing the one.
		await page.getByLabel("Wrap").click();
		await expect(file.locator(".split-diff-view-normal")).toBeVisible();
		await expect.poll(() => movedState(file)).toEqual(EXPECTED);
		// Expanding reuses the flashing cells for other lines, so it ends
		// the flash rather than leave it there.
		expect(await expandDuringFlash(file)).toEqual([]);
		await expect.poll(() => movedState(file)).toEqual(EXPECTED);

		await page.getByRole("button", { name: /^Unified$/ }).click();
		await expect(file.locator(".unified-diff-view")).toBeVisible();
		await expect.poll(() => movedState(file)).toEqual(EXPECTED);
		await expand.first().click();
		await expect.poll(() => movedState(file)).toEqual(EXPECTED);
		expect(await flashOnClick(file)).toContain(FLASH);
	} finally {
		await meerkat.kill();
	}
});

test("each moved block's icon sits in the gutter on screen, clear of code, with Wrap on or off in both views", async ({
	page,
}) => {
	// A line wider than any window makes each side's pane scroll with Wrap off.
	const meerkat = await startMeerkat({ fixture: movedBlockFixture({ wide: true }) });
	try {
		await page.setViewportSize({ width: 1000, height: 800 });
		await page.goto(meerkat.url);
		const file = page.locator(".file-section").filter({ hasText: "util.ts" });
		for (const wrap of [true, false]) {
			if (!wrap) {
				await page.getByLabel("Wrap").click();
				await expect(page.getByLabel("Wrap")).not.toBeChecked();
			}
			for (const view of ["Split", "Unified"]) {
				await page.getByRole("button", { name: new RegExp(`^${view}$`) }).click();
				const table = file.locator(`.${view.toLowerCase()}-diff-view`);
				await expect(table).toHaveCount(1);
				// A fresh load draws the table in this view from the start.
				await page.reload();
				await expect(table).toHaveCount(1);
				const message = `${view}, Wrap ${wrap ? "on" : "off"}`;
				await expect.poll(() => movedState(file), { message }).toEqual(EXPECTED);
				expect(await misplacedIcons(file), message).toEqual([]);
				// The gutter widens by the icon, so the line numbers keep their room.
				expect(await crampedNumbers(file), message).toEqual([]);
			}
		}
	} finally {
		await meerkat.kill();
	}
});

test("a moved block's icon says where the code went, jumps to it and stays out of copied code", async ({ page }) => {
	const meerkat = await startMeerkat({ fixture: movedBlockFixture() });
	try {
		// Short: the counterpart starts out of view.
		await page.setViewportSize({ width: 1000, height: 400 });
		await page.goto(meerkat.url);
		const file = page.locator(".file-section").filter({ hasText: "util.ts" });
		const link = file.getByRole("button", { name: "Moved to util.ts lines 55-59" });
		await expect(link).toBeVisible();
		await expect(link).toHaveAttribute("title", "Moved to util.ts lines 55-59");
		await expect(file.getByRole("button", { name: "Moved from util.ts lines 6-10" })).toHaveCount(1);

		const counterpart = file.locator("td.diff-line-new-num:has(span[data-line-num='55'])");
		await expect(counterpart).not.toBeInViewport();
		await link.click();
		await expect(counterpart).toBeInViewport();
		// The click is the icon's, not the gutter's: it starts no comment.
		await expect(file.locator("tr.meerkat-form-row")).toHaveCount(0);

		// Code copied across the icon's line leaves the icon out.
		const codeOn = (line: number) =>
			file.locator(`tr.diff-line:has(td.diff-line-old-num span[data-line-num='${line}']) td.diff-line-old-content`);
		await codeOn(5).scrollIntoViewIfNeeded();
		const from = await codeOn(5).boundingBox();
		const to = await codeOn(7).boundingBox();
		if (!from || !to) throw new Error("code cells have no box");
		await page.mouse.move(from.x + 40, from.y + from.height / 2);
		await page.mouse.down();
		await page.mouse.move(to.x + to.width - 20, to.y + to.height / 2, { steps: 5 });
		await page.mouse.up();
		const copied = await page.evaluate(() => window.getSelection()?.toString() ?? "");
		expect(copied).toContain("helper2(input");
		expect(copied).not.toContain("⇄");
	} finally {
		await meerkat.kill();
	}
});

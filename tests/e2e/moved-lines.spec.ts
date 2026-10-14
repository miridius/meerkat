import { writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Locator } from "@playwright/test";
import { makeFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";
import { expect, test } from "./lib/test";

// The browser seam of moved-code highlighting: DiffViewer.svelte tints
// a moved block's rows and puts an arrow over each line's +/− mark, the
// first linking to its counterpart, in a table @git-diff-view
// re-renders. Finding the moves is covered by the Meerkat.Moves tests.

const helper = (n: number) =>
	`export function helper${n}(input: string, options: { locale: string; strict: boolean }): string {
  const trimmed${n} = input.trim().toLowerCase();
  return trimmed${n}.slice(0, ${n});
}
`;

// helper2 moves to the end of the file, leaving collapsed context above
// and between the hunks. It and its blank line are lines 6-10, and land
// on lines 55-59 with the blank first. helper8's second line, old line
// 37 and new line 32, changes in place.
// `wide` ends helper1's first line in a comment wider than any window.
function movedBlockFixture({ wide = false } = {}) {
	const helpers = Array.from({ length: 12 }, (_, i) => helper(i + 1));
	if (wide) helpers[0] = helpers[0].replace("{\n", `{ // ${"wide ".repeat(100)}\n`);
	const fixture = makeFixture({ files: { "util.ts": helpers.join("\n") } });
	fixture.git("commit", "-q", "-m", "base");
	helpers[7] = helpers[7].replace(".trim()", ".trimEnd()");
	const [moved] = helpers.splice(1, 1);
	writeFileSync(join(fixture.dir, "util.ts"), [...helpers, moved].join("\n"));
	fixture.git("add", "util.ts");
	return fixture;
}

const NEW_MOVED = [55, 56, 57, 58, 59].map((n) => `new:${n}`);
const OLD_MOVED = [6, 7, 8, 9, 10].map((n) => `old:${n}`);
const EXPECTED = {
	tinted: [...NEW_MOVED, ...OLD_MOVED].sort(),
	arrows: [...NEW_MOVED.map((l) => `${l} →`), ...OLD_MOVED.map((l) => `${l} ←`)].sort(),
	links: ["new:55", "old:6"],
	marks: ["new:32 +", "old:37 -"],
	drawn: true,
};
const PAIR_0_TINT = "rgba(96, 165, 250, 0.18)";
const FLASH = "rgba(88, 166, 255, 0.35)";

// The `side:line` of each tinted code cell, of each arrow with its text,
// of each link and of each visible +/− mark with its text, and whether
// each tinted cell draws the tint.
function movedState(file: Locator) {
	return file.evaluate((root, tint) => {
		const lineOf = (tr: Element, side: string) =>
			tr.querySelector(`td.diff-line-${side}-num [data-line-num]`)?.getAttribute("data-line-num") ||
			tr.querySelector(`[data-line-${side}-num]`)?.getAttribute(`data-line-${side}-num`);
		const where = (el: Element) => {
			const td = el.closest("td") as Element;
			const tr = td.closest("tr") as Element;
			const side = td.classList.contains("diff-line-new-content")
				? "new"
				: td.classList.contains("diff-line-old-content") || !lineOf(tr, "new")
					? "old"
					: "new";
			return `${side}:${lineOf(tr, side)}`;
		};
		const cells = Array.from(root.querySelectorAll("td.moved-line"));
		const marks = Array.from(root.querySelectorAll(".diff-line-content-operator[data-operator]")).filter(
			(m) => getComputedStyle(m).color !== "rgba(0, 0, 0, 0)",
		);
		return {
			tinted: cells.map(where).sort(),
			arrows: Array.from(root.querySelectorAll(".moved-arrow"), (a) => `${where(a)} ${a.textContent}`).sort(),
			links: Array.from(root.querySelectorAll(".moved-badge"), where).sort(),
			marks: marks.map((m) => `${where(m)} ${m.textContent?.trim()}`).sort(),
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

// Each arrow's line, unless it sits over its line's +/− mark, inside the
// visible part of its scroll pane, and clear of every character of code.
function misplacedArrows(file: Locator) {
	return file.evaluate((root) => {
		const range = document.createRange();
		const textBoxes = (el: Element) => {
			const boxes: DOMRect[] = [];
			const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
			for (let n = walker.nextNode(); n; n = walker.nextNode()) {
				if (n.parentElement?.closest(".diff-line-content-operator")) continue;
				for (let i = 0; i < (n.textContent ?? "").length; i++) {
					range.setStart(n, i);
					range.setEnd(n, i + 1);
					const r = range.getBoundingClientRect();
					if (r.width > 0) boxes.push(r);
				}
			}
			return boxes;
		};
		return Array.from(root.querySelectorAll(".moved-arrow")).flatMap((arrow) => {
			const b = arrow.getBoundingClientRect();
			const mark = arrow.parentElement?.closest(".diff-line-content-operator");
			const m = mark?.getBoundingClientRect();
			const overMark =
				!!m && Math.abs(b.left - m.left) < 0.5 && Math.abs(b.right - m.right) < 0.5 && b.width > 0;
			const pane = (arrow.closest(".diff-table-scroll-container") ?? root).getBoundingClientRect();
			const inPane = b.left >= pane.left && b.right <= pane.right;
			const hit = textBoxes(arrow.closest("tr") as Element).some(
				(r) => r.right > b.left && r.left < b.right && r.bottom > b.top && r.top < b.bottom,
			);
			const line = arrow.closest("tr")?.textContent?.trim().slice(0, 40);
			return overMark && inPane && !hit ? [] : [`${line}: ${JSON.stringify({ overMark, inPane, hit })}`];
		});
	});
}

test("moved lines keep their tint and arrows when a collapsed section expands or the view changes, and a link flashes its counterpart", async ({
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

test("each moved line's arrow sits in the +/− column on screen, clear of code, with Wrap on or off in both views", async ({
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
				expect(await misplacedArrows(file), message).toEqual([]);
			}
		}
	} finally {
		await meerkat.kill();
	}
});

test("a moved block's first arrow says where the code went, jumps to it and stays out of copied code", async ({
	page,
}) => {
	const meerkat = await startMeerkat({ fixture: movedBlockFixture() });
	try {
		// Short: the counterpart starts out of view.
		await page.setViewportSize({ width: 1000, height: 400 });
		await page.goto(meerkat.url);
		const file = page.locator(".file-section").filter({ hasText: "util.ts" });
		const link = file.getByRole("button", { name: "Moved to util.ts lines 55-59" });
		await expect(link).toBeVisible();
		await expect(link).toHaveText("←");
		await expect(link).toHaveAttribute("title", "Moved to util.ts lines 55-59");
		await link.hover();
		await expect(link).toHaveCSS("background-color", "rgb(48, 54, 61)");
		await expect(file.getByRole("button", { name: "Moved from util.ts lines 6-10" })).toHaveText("→");

		const counterpart = file.locator("td.diff-line-new-num:has(span[data-line-num='55'])");
		await expect(counterpart).not.toBeInViewport();
		await link.click();
		await expect(counterpart).toBeInViewport();
		await expect(file.locator("tr.meerkat-form-row")).toHaveCount(0);

		// Code copied across the moved lines leaves the arrows out.
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
		expect(copied).not.toMatch(/[←→]/);
	} finally {
		await meerkat.kill();
	}
});

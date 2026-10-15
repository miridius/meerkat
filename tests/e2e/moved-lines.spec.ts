import { writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Locator } from "@playwright/test";
import { makeFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";
import { expect, test } from "./lib/test";

// The browser seam of moved-code highlighting: DiffViewer.svelte tints
// a moved block's rows and puts an arrow over each line's +/− mark, each
// a button linking to its counterpart, in a table @git-diff-view
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
	arrows: [
		...NEW_MOVED.map((l) => `${l} → Moved from util.ts lines 6-10`),
		...OLD_MOVED.map((l) => `${l} ← Moved to util.ts lines 55-59`),
	].sort(),
	marks: ["new:32 +", "old:37 -"],
	drawn: true,
};
const PAIR_0_TINT = "rgba(96, 165, 250, 0.18)";
const FLASH = "rgba(88, 166, 255, 0.35)";

// The `side:line` of each tinted code cell, of each arrow button with
// its text and name, and of each visible +/− mark with its text, and
// whether each tinted cell draws the tint.
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
			arrows: Array.from(
				root.querySelectorAll("button.moved-arrow"),
				(a) => `${where(a)} ${a.textContent} ${a.getAttribute("aria-label")}`,
			).sort(),
			marks: marks.map((m) => `${where(m)} ${m.textContent?.trim()}`).sort(),
			drawn: cells.every((td) => getComputedStyle(td).backgroundImage.includes(tint)),
		};
	}, PAIR_0_TINT);
}

// Clicks the old block's first arrow, and returns the box-shadow its
// counterpart's second code cell draws in the frame the flash starts:
// the jump round-trips through the server, and the flash lasts only 1.6s.
function flashOnClick(file: Locator) {
	return file.evaluate(async (root) => {
		(root.querySelector(".moved-arrow") as HTMLElement).click();
		const deadline = performance.now() + 3000;
		while (!Array.from(root.querySelectorAll("td")).some((td) => td.getAnimations().length > 0)) {
			if (performance.now() > deadline) throw new Error("no flash");
			await new Promise((r) => requestAnimationFrame(r));
		}
		const tr = root.querySelector(
			'tr.diff-line:has(td.diff-line-new-num [data-line-num="56"], [data-line-new-num="56"])',
		) as Element;
		const td = tr.querySelector("td.diff-line-new-content, td.diff-line-content") as Element;
		return getComputedStyle(td).boxShadow;
	});
}

// Clicks the old block's first arrow, then, in the frame the flash
// starts, a visible Expand button, and returns the line numbers of the
// cells still flashing two frames later, well inside the 1.6s flash.
function expandDuringFlash(file: Locator) {
	return file.evaluate(async (root) => {
		const flashing = () => Array.from(root.querySelectorAll("td")).filter((td) => td.getAnimations().length > 0);
		(root.querySelector(".moved-arrow") as HTMLElement).click();
		const deadline = performance.now() + 3000;
		while (flashing().length === 0) {
			if (performance.now() > deadline) throw new Error("no flash");
			await new Promise((r) => requestAnimationFrame(r));
		}
		const expand = Array.from(
			root.querySelectorAll<HTMLElement>('td.diff-line-hunk-action button[title^="Expand"]'),
		).find((b) => b.checkVisibility());
		(expand as HTMLElement).click();
		await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
		return flashing().map((td) => td.closest("tr")?.querySelector("[data-line-num]")?.getAttribute("data-line-num"));
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

test("moved lines keep their tint and arrows when a collapsed section expands or the view changes, and an arrow flashes its counterpart", async ({
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
		await page.getByRole("checkbox", { name: "Wrap" }).click();
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

		// A counterpart already on the page needs no round trip to the server.
		const flashing = () =>
			file.evaluate((root) => Array.from(root.querySelectorAll("td")).some((td) => td.getAnimations().length > 0));
		await expect.poll(flashing).toBe(false);
		await page.evaluate(() => (window as unknown as { liveSocket: { disconnect(): void } }).liveSocket.disconnect());
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

test("every moved line's arrow is a button that says where the code went and jumps to it by mouse or keyboard, opening its file if collapsed", async ({
	page,
}) => {
	// helper2 moves from a.ts to the end of b.ts, as old lines 6-10 and
	// new lines 5-9 with the blank first.
	const fixture = makeFixture({ files: { "a.ts": [1, 2, 3].map(helper).join("\n"), "b.ts": helper(4) } });
	fixture.git("commit", "-q", "-m", "base");
	writeFileSync(join(fixture.dir, "a.ts"), [1, 3].map(helper).join("\n"));
	writeFileSync(join(fixture.dir, "b.ts"), [4, 2].map(helper).join("\n"));
	fixture.git("add", "a.ts", "b.ts");
	const meerkat = await startMeerkat({ fixture });
	try {
		// Short: the counterpart starts out of view.
		await page.setViewportSize({ width: 1000, height: 400 });
		await page.goto(meerkat.url);
		const file = page.locator(".file-section").filter({ hasText: "a.ts" });
		const target = page.locator(".file-section").filter({ hasText: "b.ts" });
		const oldArrows = file.getByRole("button", { name: "Moved to b.ts lines 5-9", exact: true });
		await expect(oldArrows).toHaveCount(5);
		await expect(oldArrows).toHaveText(Array(5).fill("←"));
		await expect(oldArrows.nth(2)).toHaveAttribute("title", "Moved to b.ts lines 5-9");
		await expect(target.getByRole("button", { name: "Moved from a.ts lines 6-10", exact: true })).toHaveText(
			Array(5).fill("→"),
		);
		await oldArrows.nth(2).hover();
		await expect(oldArrows.nth(2)).toHaveCSS("background-color", "rgb(48, 54, 61)");

		const counterpart = target.locator("td.diff-line-new-num:has(span[data-line-num='5'])");
		const scrollToTop = () => page.evaluate(() => window.scrollTo(0, 0));
		await expect(counterpart).not.toBeInViewport();
		await oldArrows.last().click();
		await expect(counterpart).toBeInViewport();
		await expect(file.locator("tr.meerkat-form-row")).toHaveCount(0);

		// Tab moves from one arrow to the next, which shows the focus ring,
		// and Enter jumps.
		await scrollToTop();
		await oldArrows.first().focus();
		await page.keyboard.press("Tab");
		await expect(oldArrows.nth(1)).toBeFocused();
		await expect(oldArrows.nth(1)).toHaveCSS("box-shadow", /rgba\(88, 166, 255, 0\.5\)/);
		await expect(counterpart).not.toBeInViewport();
		await page.keyboard.press("Enter");
		await expect(counterpart).toBeInViewport();

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

		// A collapsed counterpart's file opens, and all its lines flash.
		await target.locator("button.file-row").click();
		await expect(counterpart).toHaveCount(0);
		await oldArrows.nth(2).click();
		await expect(counterpart).toBeInViewport();
		const flashingRows = () =>
			target.evaluate(
				(root) =>
					new Set(
						Array.from(root.querySelectorAll("td"))
							.filter((td) => td.getAnimations().length > 0)
							.map((td) => td.closest("tr")),
					).size,
			);
		await expect.poll(flashingRows).toBe(5);
	} finally {
		await meerkat.kill();
	}
});

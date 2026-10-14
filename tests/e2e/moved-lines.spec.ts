import { writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Locator } from "@playwright/test";
import { makeFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";
import { expect, test } from "./lib/test";

// The browser seam of moved-code highlighting: DiffViewer.svelte tints
// a moved block's rows and puts a link to its counterpart on the first,
// in a table @git-diff-view re-renders. Finding the moves is covered by
// the Meerkat.Moves tests.

const helper = (n: number) =>
	`export function helper${n}(input: string, options: { locale: string; strict: boolean }): string {
  const trimmed${n} = input.trim().toLowerCase();
  return trimmed${n}.slice(0, ${n});
}
`;

// helper2 moves to the end of the file, leaving collapsed context above
// and between the hunks. Its lines 6-8 are long enough to count as
// moved, and land on lines 56-58.
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

const MOVED = ["new:56", "new:57", "new:58", "old:6", "old:7", "old:8"];
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
			const side = td.classList.contains("diff-line-new-content")
				? "new"
				: td.classList.contains("diff-line-old-content") || !lineOf(tr, "new")
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

test("moved lines keep their tint and links when a collapsed section expands or the view changes, and a link flashes its counterpart", async ({
	page,
}) => {
	const meerkat = await startMeerkat({ fixture: movedBlockFixture() });
	try {
		await page.goto(meerkat.url);
		const file = page.locator(".file-section").filter({ hasText: "util.ts" });
		const expected = { tinted: MOVED, links: ["new:56", "old:6"], drawn: true };
		await expect.poll(() => movedState(file)).toEqual(expected);

		expect(await flashOnClick(file)).toContain(FLASH);

		// Expanding inserts rows above the moved ones; @git-diff-view reuses
		// the existing row elements for the lines that shift into them.
		const expand = file.locator('td.diff-line-hunk-action button[title^="Expand"]').filter({ visible: true });
		await expand.first().click();
		await expect.poll(() => movedState(file)).toEqual(expected);

		// Each toggle round-trips through the server before the table is
		// replaced, so wait for the new table, or the poll reads the old one.
		// Split view without wrap is two tables of rows, replacing the one.
		await page.getByLabel("Wrap").click();
		await expect(file.locator(".split-diff-view-normal")).toBeVisible();
		await expect.poll(() => movedState(file)).toEqual(expected);
		// Expanding reuses the flashing cells for other lines, so it ends
		// the flash rather than leave it there.
		expect(await expandDuringFlash(file)).toEqual([]);
		await expect.poll(() => movedState(file)).toEqual(expected);

		await page.getByRole("button", { name: /^Unified$/ }).click();
		await expect(file.locator(".unified-diff-view")).toBeVisible();
		await expect.poll(() => movedState(file)).toEqual(expected);
		await expand.first().click();
		await expect.poll(() => movedState(file)).toEqual(expected);
		expect(await flashOnClick(file)).toContain(FLASH);
	} finally {
		await meerkat.kill();
	}
});

test("with Wrap off, a fresh load tints moved lines and links them in both views", async ({ page }) => {
	const meerkat = await startMeerkat({ fixture: movedBlockFixture({ wide: true }) });
	try {
		await page.goto(meerkat.url);
		await page.getByLabel("Wrap").click();
		await expect(page.getByLabel("Wrap")).not.toBeChecked();
		for (const view of ["Split", "Unified"]) {
			await page.getByRole("button", { name: new RegExp(`^${view}$`) }).click();
			// A fresh load draws the Wrap-off table from the start.
			await page.reload();
			const file = page.locator(".file-section").filter({ hasText: "util.ts" });
			await expect
				.poll(() => movedState(file), { message: view })
				.toEqual({ tinted: MOVED, links: ["new:56", "old:6"], drawn: true });
		}
	} finally {
		await meerkat.kill();
	}
});

test("a moved block's link covers none of its code, stays out of copied code and jumps to the counterpart", async ({ page }) => {
	const meerkat = await startMeerkat({ fixture: movedBlockFixture() });
	try {
		// Narrow and short: the first moved line wraps, and the counterpart
		// starts out of view.
		await page.setViewportSize({ width: 1000, height: 400 });
		await page.goto(meerkat.url);
		const file = page.locator(".file-section").filter({ hasText: "util.ts" });
		const link = file.locator(".moved-badge", { hasText: "util.ts:56-58" });
		await expect(link).toBeVisible();

		const covered = await link.evaluate((badge) => {
			const b = badge.getBoundingClientRect();
			const walker = document.createTreeWalker(badge.closest("td") as Node, NodeFilter.SHOW_TEXT);
			const range = document.createRange();
			let hidden = "";
			for (let n = walker.nextNode(); n; n = walker.nextNode()) {
				if (badge.contains(n)) continue;
				for (let i = 0; i < (n.textContent ?? "").length; i++) {
					range.setStart(n, i);
					range.setEnd(n, i + 1);
					const r = range.getBoundingClientRect();
					if (r.width > 0 && r.right > b.left && r.left < b.right && r.bottom > b.top && r.top < b.bottom)
						hidden += n.textContent?.[i];
				}
			}
			return hidden;
		});
		expect(covered).toBe("");

		const counterpart = file.locator("td.diff-line-new-num:has(span[data-line-num='56'])");
		await expect(counterpart).not.toBeInViewport();
		await link.click();
		await expect(counterpart).toBeInViewport();

		// Code copied across the link's line leaves the link's text out.
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
		expect(copied).not.toContain("util.ts:56-58");
	} finally {
		await meerkat.kill();
	}
});

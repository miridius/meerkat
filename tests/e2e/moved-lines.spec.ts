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
function movedBlockFixture() {
	const helpers = Array.from({ length: 12 }, (_, i) => helper(i + 1));
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
		await page.getByRole("checkbox", { name: "Wrap" }).click();
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

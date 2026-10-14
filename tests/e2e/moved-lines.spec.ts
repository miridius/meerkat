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

// helper2 moves to the end of the file, leaving collapsed context above,
// between and below the hunks. Its lines 6-8 are long enough to count as
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

test("moved lines keep their tint and links when a collapsed section expands or the view changes", async ({
	page,
}) => {
	const meerkat = await startMeerkat({ fixture: movedBlockFixture() });
	try {
		await page.goto(meerkat.url);
		const file = page.locator(".file-section").filter({ hasText: "util.ts" });
		const expected = { tinted: MOVED, links: ["new:56", "old:6"], drawn: true };
		await expect.poll(() => movedState(file)).toEqual(expected);

		// Expanding inserts rows above the moved ones; @git-diff-view reuses
		// the existing row elements for the lines that shift into them.
		const expand = file.locator('td.diff-line-hunk-action button[title^="Expand"]').filter({ visible: true });
		await expand.first().click();
		await expect.poll(() => movedState(file)).toEqual(expected);

		await page.getByRole("button", { name: /^Unified$/ }).click();
		await expect.poll(() => movedState(file)).toEqual(expected);
		await expand.first().click();
		await expect.poll(() => movedState(file)).toEqual(expected);

		await page.getByLabel("Wrap").click();
		await expect(page.getByLabel("Wrap")).not.toBeChecked();
		await expect.poll(() => movedState(file)).toEqual(expected);
	} finally {
		await meerkat.kill();
	}
});

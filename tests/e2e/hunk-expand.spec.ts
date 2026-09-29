import { writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Locator } from "@playwright/test";
import { expect, test } from "./lib/test";
import { startMeerkat } from "./lib/runner";
import { makeFixture } from "./lib/fixture";

// The 80-line fixture edits lines 20 and 60, leaving hidden lines
// above the first hunk, in the 32-line gap between hunks, and below
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

for (const wrap of [true, false]) {
	test.describe(`split-mode hunk expand buttons (wrap ${wrap ? "on" : "off"})`, () => {
		test("sit in the right-hand gutter only, and expand the hidden lines", async ({ page }) => {
			const meerkat = await startMeerkat({ fixture: twoHunkFixture() });
			try {
				await page.goto(meerkat.url);
				const wrapToggle = page.locator(".diff-toolbar .wrap-toggle input[type=checkbox]");
				await expect(wrapToggle).toBeChecked();
				if (!wrap) await wrapToggle.uncheck();

				const file = page.locator(".file-section").filter({ hasText: "a.txt" });
				const expandButtons = file.locator(
					'td.diff-line-hunk-action button[title^="Expand"]',
				);
				const visible = expandButtons.filter({ visible: true });
				// The three visible buttons are Expand Up on the first hunk, Expand All
				// between hunks, and Expand Down after the last. The 32-line
				// gap is shorter than @git-diff-view's composeLen (40), so it
				// offers a single Expand All button.
				await expect(visible).toHaveCount(3);

				const gutter = await newGutterSpan(file);
				for (const button of await visible.all()) {
					const box = await button.boundingBox();
					if (!box) throw new Error("visible expand button has no box");
					const centre = box.x + box.width / 2;
					expect(centre).toBeGreaterThanOrEqual(gutter.left);
					expect(centre).toBeLessThanOrEqual(gutter.right);
				}

				await expect(file.getByText("line 40", { exact: true }).first()).toBeHidden();
				await file.locator('button[title="Expand All"]').filter({ visible: true }).click();
				await expect(file.getByText("line 40", { exact: true }).first()).toBeVisible();
			} finally {
				await meerkat.kill();
			}
		});
	});
}

test("unified-mode hunk expand buttons stay in the single gutter", async ({ page }) => {
	const meerkat = await startMeerkat({ fixture: twoHunkFixture() });
	try {
		await page.goto(meerkat.url);
		await page.getByRole("button", { name: /^Unified$/ }).click();

		const file = page.locator(".file-section").filter({ hasText: "a.txt" });
		await expect(file.locator("td.diff-line-new-num")).toHaveCount(0);
		const visible = file
			.locator('td.diff-line-hunk-action button[title^="Expand"]')
			.filter({ visible: true });
		await expect(visible).toHaveCount(3);

		const gutter = await file.locator("td.diff-line-num").first().boundingBox();
		if (!gutter) throw new Error("unified gutter cell has no box");
		for (const button of await visible.all()) {
			const box = await button.boundingBox();
			if (!box) throw new Error("visible expand button has no box");
			expect(box.x).toBeGreaterThanOrEqual(gutter.x - 1);
			expect(box.x + box.width).toBeLessThanOrEqual(gutter.x + gutter.width + 1);
		}
	} finally {
		await meerkat.kill();
	}
});

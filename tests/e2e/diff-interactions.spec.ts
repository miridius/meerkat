import { writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Locator, Page } from "@playwright/test";
import { expect, test } from "./lib/test";
import { startMeerkat } from "./lib/runner";
import { makeFixture } from "./lib/fixture";

// DiffViewer uses PointerEvent + setPointerCapture for gutter drags.
//
// An added file (status A) is forced into unified mode regardless of
// the toolbar toggle (the empty old side wastes ~half the viewport on
// one-sided diffs). Unified mode renders a single `td.diff-line-num`
// cell containing inner spans tagged with `data-line-new-num` /
// `data-line-old-num`. A modified file follows the toggle; in split
// mode the number spans have `pointer-events: none` since
// @git-diff-view 0.1.4, so the td is the event target.
//
// How the view stores the range and renders the saved comment is
// covered by the LiveView tests.

async function commentOnDrag(page: Page, from: Locator, to: Locator, body: string) {
	await from.dragTo(to);
	const form = page.locator(".comment-form");
	await expect(form).toBeVisible();
	await form.locator("textarea").fill(body);
	await form.getByRole("button", { name: /^Add Comment$/ }).click();
	await expect(form).toBeHidden();
}

test.describe("diff gutter drag selection", () => {
	test("a drag shades only the lines and side in its range while it lasts, and in unified and in split mode comments on the whole range dragged over", async ({
		page,
	}) => {
		const fixture = makeFixture({ files: { "src/lib.rs": "fn a() {}\nfn b() {}\nfn c() {}\n" } });
		fixture.git("commit", "-q", "-m", "base");
		writeFileSync(
			join(fixture.dir, "src/lib.rs"),
			"fn a() {}\nfn b2() {}\nfn c() {}\nfn d() {}\nfn e() {}\n",
		);
		writeFileSync(join(fixture.dir, "src/added.rs"), "fn one() {}\nfn two() {}\nfn three() {}\n");
		fixture.git("add", "src/lib.rs", "src/added.rs");

		const meerkat = await startMeerkat({ fixture });
		try {
			await page.goto(meerkat.url);

			const added = page.locator(".file-section").filter({ hasText: "src/added.rs" });
			const modified = page.locator(".file-section").filter({ hasText: "src/lib.rs" });
			const shade = "rgba(31, 111, 235, 0.32)";

			// In the added file's unified gutter, the lines in a drag's range
			// are highlighted over the add shading.
			const addedLines = added.locator("td.diff-line-num span[data-line-new-num]");
			await addedLines.nth(0).hover();
			await page.mouse.down();
			await addedLines.nth(2).hover();
			const numCell = added.locator("td.diff-line-num.drag-selecting").first();
			const codeCell = added.locator("tr.drag-selecting > td:not(.diff-line-num)").first();
			await expect(numCell).toHaveCSS("background-color", shade);
			await expect(numCell).toHaveCSS("color", "rgb(255, 255, 255)");
			await expect(codeCell).toHaveCSS("background-color", shade);
			await page.mouse.up();
			await added.locator(".comment-form").getByRole("button", { name: /^Cancel$/ }).click();
			await expect(page.locator(".comment-form")).toHaveCount(0);

			// In the modified file's split gutter, only the dragged side is
			// shaded, and only for as long as a row is in the range.
			const splitCell = (line: number) =>
				modified.locator(`td.diff-line-new-num:has(span[data-line-num="${line}"])`);
			await expect(splitCell(1), "the modified file renders split").toBeVisible();
			await splitCell(1).hover();
			await page.mouse.down();
			await splitCell(3).hover();
			const row = modified.locator('tr.diff-line:has(td.diff-line-new-num span[data-line-num="1"])');
			await expect(row.locator("td.diff-line-new-content")).toHaveCSS("background-color", shade);
			await expect(row.locator("td.diff-line-old-num")).not.toHaveCSS("background-color", shade);
			await expect(row.locator("td.diff-line-old-content")).not.toHaveCSS("background-color", shade);
			const lastRow = modified.locator('tr.diff-line:has(td.diff-line-new-num span[data-line-num="3"])');
			await expect(lastRow.locator("td.diff-line-new-content")).toHaveCSS("background-color", shade);
			await splitCell(1).hover();
			await expect(
				lastRow.locator("td.diff-line-new-content"),
				"shrinking the drag unshades the rows it leaves",
			).not.toHaveCSS("background-color", shade);
			await page.mouse.up();
			await expect(
				row.locator("td.diff-line-new-content"),
				"releasing the drag unshades its rows",
			).not.toHaveCSS("background-color", shade);
			await modified.locator(".comment-form").getByRole("button", { name: /^Cancel$/ }).click();
			await expect(page.locator(".comment-form")).toHaveCount(0);

			await expect(added.locator("td.diff-line-num").first()).toBeVisible();
			await page.getByRole("button", { name: /^Unified$/ }).click();
			await page.getByRole("button", { name: /^Split$/ }).click();
			await expect(
				added.locator("td.diff-line-new-num"),
				"the added file stays unified in split mode",
			).toHaveCount(0);

			await commentOnDrag(page, addedLines.nth(0), addedLines.nth(2), "unified range");
			await expect(
				added.locator("tr.diff-line.has-inline-comment"),
				"the unified comment covers lines 1 to 3",
			).toHaveCount(3);

			await commentOnDrag(page, splitCell(1), splitCell(4), "split range");
			await expect(
				modified.locator("tr.diff-line.has-inline-comment"),
				"the split comment covers lines 1 to 4",
			).toHaveCount(4);
		} finally {
			await meerkat.kill();
		}
	});
});

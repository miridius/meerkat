import { expect, test } from "./lib/test";
import { startMeerkat } from "./lib/runner";

// Pointer-event helpers — Playwright's high-level click/drag does
// MouseEvent dispatch, but DiffViewer uses PointerEvent +
// setPointerCapture, so we drive the browser's pointer pipeline
// directly via mouse.move / mouse.down / mouse.up.
//
// `src/main.rs` is added (status A), which DiffViewer forces into
// unified mode regardless of the toolbar toggle (the empty old
// side wastes ~half the viewport on one-sided diffs). Unified
// mode renders a single `td.diff-line-num` cell containing inner
// spans tagged with `data-line-new-num` / `data-line-old-num`.

test.describe("diff line click + drag selection", () => {
	test("clicking a single line opens the comment form anchored at that line", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			const fileSection = page.locator(".file-section").filter({ hasText: "src/main.rs" });
			const firstNewLine = fileSection
				.locator("td.diff-line-num span[data-line-new-num]")
				.first();
			await expect(firstNewLine).toBeVisible();

			await firstNewLine.click();

			await expect(page.locator(".comment-form")).toBeVisible();
		} finally {
			await meerkat.kill();
		}
	});

	test("dragging across two lines opens a multi-line range form", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			const fileSection = page.locator(".file-section").filter({ hasText: "src/main.rs" });
			const lines = fileSection.locator("td.diff-line-num span[data-line-new-num]");
			const startLine = lines.nth(0);
			const endLine = lines.nth(2);

			await startLine.dragTo(endLine);

			await expect(page.locator(".comment-form")).toBeVisible();
		} finally {
			await meerkat.kill();
		}
	});
});

test.describe("diff toolbar mode toggle", () => {
	test("Split toggle has no effect on one-sided diffs; toggle still updates state", async ({
		page,
	}) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			const file = page.locator(".file-section").filter({ hasText: "src/main.rs" });

			// Added file → unified regardless of toggle state.
			await expect(file.locator("td.diff-line-num").first()).toBeVisible();
			await expect(file.locator("td.diff-line-new-num")).toHaveCount(0);

			// Toolbar toggle still flips the LV's diff_mode assign;
			// other files (modified) would respect it. The added-file
			// stays unified because DiffViewer forces it.
			await page.getByRole("button", { name: /^Unified$/ }).click();
			await expect(file.locator("td.diff-line-num").first()).toBeVisible();
			await page.getByRole("button", { name: /^Split$/ }).click();
			await expect(file.locator("td.diff-line-num").first()).toBeVisible();
		} finally {
			await meerkat.kill();
		}
	});
});

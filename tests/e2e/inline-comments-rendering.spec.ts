import { expect, test } from "./lib/test";
import { startMeerkat } from "./lib/runner";

// Behaviour shipped via DOM injection in DiffViewer.svelte:
// - Comment form is mounted as <tr class="meerkat-form-row"> AFTER
//   the drag-end row, INSIDE the @git-diff-view table.
// - Submitted comments render as <tr class="meerkat-comment-row">
//   at the same anchor.
// - Rows covered by a comment range get .has-inline-comment.
// - Re-rendering tears down stale rows (no duplicates).
// The server side of adding, removing and flagging comments is covered
// by the LiveView tests.
//
// `src/main.rs` (status A) renders in unified mode: a single
// combined line-num cell (`td.diff-line-num`) holding both old- and
// new-num spans tagged with `data-line-{old,new}-num`. Added files
// only carry a new-num, so that's the anchor the test picks.
test.describe("inline comments: DOM-injection rendering", () => {
	test("comments submitted by button and by Cmd+Enter render as rows at their anchors, mark the anchor row, and go on Remove", async ({
		page,
	}) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			const fileSection = page.locator(".file-section").filter({ hasText: "src/main.rs" });
			const lines = fileSection.locator("td.diff-line-num span[data-line-new-num]");
			const form = page.locator(".comment-form");

			await lines.first().click();
			await expect(form).toBeVisible();
			await expect(
				form.locator("input[type=checkbox]"),
				"learn-from-this defaults off",
			).not.toBeChecked();
			await form.locator("textarea").fill("first");
			await form.getByRole("button", { name: /^Add Comment$/ }).click();
			await expect(form).toBeHidden();

			await lines.nth(2).click();
			// Meta+Enter on macOS / Ctrl+Enter elsewhere: both map to
			// our handler because the JS check is (metaKey || ctrlKey).
			await form.locator("textarea").fill("second");
			await form.locator("textarea").press("Meta+Enter");
			await expect(form, "Cmd+Enter inside the form submits").toBeHidden();

			const rows = fileSection.locator("tr.meerkat-comment-row");
			await expect(rows, "each comment gets exactly one row").toHaveCount(2);
			await expect(rows.nth(0).locator(".inline-comment .comment-body")).toContainText("first");
			await expect(rows.nth(1).locator(".inline-comment .comment-body")).toContainText("second");

			const anchorRow = fileSection
				.locator('tr.diff-line:has(td.diff-line-num span[data-line-new-num="1"])')
				.first();
			await expect(anchorRow).toHaveClass(/has-inline-comment/);

			const learn = rows.nth(0).locator(".inline-comment .learn-toggle input");
			await expect(learn).not.toBeChecked();
			await learn.check();
			await expect(learn, "the rendered comment's learn toggle flips").toBeChecked();

			await rows.nth(0).getByRole("button", { name: /^Remove$/ }).click();
			await expect(rows).toHaveCount(1);
			await expect(rows.first().locator(".comment-body")).toContainText("second");
			await expect(anchorRow, "the marker clears with its comment").not.toHaveClass(
				/has-inline-comment/,
			);
		} finally {
			await meerkat.kill();
		}
	});
});

import { type Locator } from "@playwright/test";
import { expect, test } from "./lib/test";
import { startMeerkat } from "./lib/runner";

// Behaviour shipped via DOM injection in DiffViewer.svelte:
// - Comment form is mounted as <tr class="meerkat-form-row"> AFTER
//   the drag-end row, INSIDE the @git-diff-view table.
// - Submitted comments render as <tr class="meerkat-comment-row">
//   at the same anchor; multiple comments at same anchor stack.
// - Rows covered by a comment range get .has-inline-comment.
// - Re-opening / re-rendering tears down stale rows (no duplicates).
//
// `src/main.rs` (status A) renders in unified mode: a single
// combined line-num cell (`td.diff-line-num`) holding both old- and
// new-num spans tagged with `data-line-{old,new}-num`. Added files
// only carry a new-num — that's the anchor each test below picks.
function firstAddedFileLine(fileSection: Locator): Locator {
	return fileSection.locator("td.diff-line-num span[data-line-new-num]").first();
}

test.describe("inline comments — DOM-injection rendering", () => {
	test("submitted comment appears as a meerkat-comment-row at the anchor", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			const fileSection = page.locator(".file-section").filter({ hasText: "src/main.rs" });
			await firstAddedFileLine(fileSection).click();

			const form = page.locator(".comment-form");
			await expect(form).toBeVisible();
			await form.locator("textarea").fill("rendered-comment-test");
			await form.getByRole("button", { name: /^Add Comment$/ }).click();

			// Form closes; an injected meerkat-comment-row hosts the
			// rendered InlineComment.
			await expect(form).toBeHidden();
			const commentRow = fileSection.locator("tr.meerkat-comment-row").first();
			await expect(commentRow).toBeVisible();
			await expect(commentRow.locator(".inline-comment .comment-body")).toContainText(
				"rendered-comment-test",
			);
		} finally {
			await meerkat.kill();
		}
	});

	test("Cmd+Enter inside the form submits", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			const fileSection = page.locator(".file-section").filter({ hasText: "src/main.rs" });
			await firstAddedFileLine(fileSection).click();

			const ta = page.locator(".comment-form textarea");
			await ta.fill("submitted via shortcut");
			// Meta+Enter on macOS / Ctrl+Enter elsewhere — both map to
			// our handler because the JS check is (metaKey || ctrlKey).
			await ta.press("Meta+Enter");

			await expect(page.locator(".comment-form")).toBeHidden();
			await expect(
				fileSection.locator("tr.meerkat-comment-row .comment-body"),
			).toContainText("submitted via shortcut");
		} finally {
			await meerkat.kill();
		}
	});

	test("learn-from-this defaults off; toggle on rendered comment flips it", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			const fileSection = page.locator(".file-section").filter({ hasText: "src/main.rs" });
			await firstAddedFileLine(fileSection).click();

			// Default off: the form's checkbox is unchecked at first paint.
			const formLearn = page.locator(".comment-form input[type=checkbox]");
			await expect(formLearn).not.toBeChecked();

			const ta = page.locator(".comment-form textarea");
			await ta.fill("learn toggle smoke");
			await page.getByRole("button", { name: /^Add Comment$/ }).click();
			await expect(page.locator(".comment-form")).toBeHidden();

			// Rendered comment has an inline learn checkbox; toggle it.
			const renderedCheckbox = fileSection
				.locator("tr.meerkat-comment-row .inline-comment .learn-toggle input")
				.first();
			await expect(renderedCheckbox).not.toBeChecked();
			await renderedCheckbox.check();
			await expect(renderedCheckbox).toBeChecked();
		} finally {
			await meerkat.kill();
		}
	});

	test("two inline comments at different anchors coexist", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			const fileSection = page.locator(".file-section").filter({ hasText: "src/main.rs" });
			const lines = fileSection.locator("td.diff-line-num span[data-line-new-num]");

			// First comment at line 1.
			await lines.first().click();
			await page.locator(".comment-form textarea").fill("first");
			await page.getByRole("button", { name: /^Add Comment$/ }).click();
			await expect(page.locator(".comment-form")).toBeHidden();

			// Second comment at line 3.
			await lines.nth(2).click();
			await page.locator(".comment-form textarea").fill("second");
			await page.getByRole("button", { name: /^Add Comment$/ }).click();
			await expect(page.locator(".comment-form")).toBeHidden();

			// Two distinct meerkat-comment-rows.
			const rows = fileSection.locator("tr.meerkat-comment-row");
			await expect(rows).toHaveCount(2);
			await expect(rows.nth(0).locator(".comment-body")).toContainText("first");
			await expect(rows.nth(1).locator(".comment-body")).toContainText("second");
		} finally {
			await meerkat.kill();
		}
	});

	test("Remove button drops the inline comment + its row", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			const fileSection = page.locator(".file-section").filter({ hasText: "src/main.rs" });
			await firstAddedFileLine(fileSection).click();
			await page.locator(".comment-form textarea").fill("about to be removed");
			await page.getByRole("button", { name: /^Add Comment$/ }).click();
			await expect(page.locator(".comment-form")).toBeHidden();

			const commentRow = fileSection.locator("tr.meerkat-comment-row").first();
			await expect(commentRow).toBeVisible();
			await commentRow.getByRole("button", { name: /^Remove$/ }).click();
			await expect(fileSection.locator("tr.meerkat-comment-row")).toHaveCount(0);
		} finally {
			await meerkat.kill();
		}
	});

	test("anchor row gets .has-inline-comment marker; clears on remove", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			const fileSection = page.locator(".file-section").filter({ hasText: "src/main.rs" });
			// Added-file unified-mode selector (see comment in earlier test).
			const lines = fileSection.locator("td.diff-line-num span[data-line-new-num]");
			await lines.first().click();
			await page.locator(".comment-form textarea").fill("marker test");
			await page.getByRole("button", { name: /^Add Comment$/ }).click();
			await expect(page.locator(".comment-form")).toBeHidden();

			// Anchor row carries the marker. Use the row hosting the
			// data-line-new-num="1" span — that's the line we anchored.
			const anchorRow = fileSection
				.locator('tr.diff-line:has(td.diff-line-num span[data-line-new-num="1"])')
				.first();
			await expect(anchorRow).toHaveClass(/has-inline-comment/);

			// Remove → marker clears.
			await fileSection.getByRole("button", { name: /^Remove$/ }).first().click();
			await expect(anchorRow).not.toHaveClass(/has-inline-comment/);
		} finally {
			await meerkat.kill();
		}
	});
});

test.describe("approved files collapse", () => {
	test("approving a file hides the diff body; header re-expands it", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			const fileSection = page.locator(".file-section").filter({ hasText: "src/main.rs" });
			// Diff body visible by default.
			await expect(fileSection.locator(".diff-content")).toBeVisible();

			// Tick the per-file Approved checkbox.
			await fileSection.locator("input[type=checkbox]").first().check();

			// Diff body disappears; section gets .collapsed.
			await expect(fileSection.locator(".diff-content")).toBeHidden();
			await expect(fileSection).toHaveClass(/collapsed/);

			// Click the file header → diff body returns.
			await fileSection.locator(".file-row").click();
			await expect(fileSection.locator(".diff-content")).toBeVisible();
			await expect(fileSection).not.toHaveClass(/collapsed/);
		} finally {
			await meerkat.kill();
		}
	});

	test("unapproved files collapse on header click and re-expand on a second click", async ({
		page,
	}) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			const fileSection = page.locator(".file-section").filter({ hasText: "src/main.rs" });
			// Unapproved files default-expand.
			await expect(fileSection.locator(".diff-content")).toBeVisible();

			// First header click collapses the unapproved file.
			await fileSection.locator(".file-row").click();
			await expect(fileSection.locator(".diff-content")).toBeHidden();
			await expect(fileSection).toHaveClass(/collapsed/);

			// Second click re-expands.
			await fileSection.locator(".file-row").click();
			await expect(fileSection.locator(".diff-content")).toBeVisible();
			await expect(fileSection).not.toHaveClass(/collapsed/);
		} finally {
			await meerkat.kill();
		}
	});
});

test.describe("wrap lines default", () => {
	test("Wrap toolbar toggle starts checked", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);
			// `.wrap-toggle` wraps a checkbox + label. Toolbar lives
			// outside any file-section.
			const wrapToggle = page.locator(".diff-toolbar .wrap-toggle input[type=checkbox]");
			await expect(wrapToggle).toBeChecked();
		} finally {
			await meerkat.kill();
		}
	});
});

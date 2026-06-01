import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test } from "./lib/test";
import { startMeerkat } from "./lib/runner";
import { makeFixture } from "./lib/fixture";

// Per-file Diff⇄Rendered toggle on markdown files. The rendered view
// is a side-by-side Old | New of the markdown rendered to HTML, with
// changed blocks tinted red (removed, old pane) / green (added, new
// pane). It replaces the diff body; line comments aren't shown there.

const OLD = "# README\n\nOld intro paragraph.\n\nShared middle.\n";
const NEW = "# README\n\nNew intro paragraph.\n\nShared middle.\n\nBrand new tail.\n";

// A README.md that is committed then modified, so meerkat sees a real
// `:modified` markdown diff (makeFixture alone only stages additions).
function modifiedMarkdownFixture() {
	const fixture = makeFixture({ files: { "README.md": OLD } });
	fixture.git("commit", "-q", "-m", "base readme");
	writeFileSync(join(fixture.dir, "README.md"), NEW);
	fixture.git("add", "README.md");
	return fixture;
}

test.describe("markdown rendered view", () => {
	test("toggle swaps diff for side-by-side rendered panes with red/green tints, and back", async ({
		page,
	}) => {
		const meerkat = await startMeerkat({ fixture: modifiedMarkdownFixture() });
		try {
			await page.goto(meerkat.url);

			const section = page.locator(".file-section").filter({ hasText: "README.md" });
			await expect(section.locator(".diff-content")).toBeVisible();
			await expect(section.locator(".md-preview")).toHaveCount(0);

			await section.locator("button.md-view-toggle").click();

			const preview = section.locator(".md-preview");
			await expect(preview).toBeVisible();
			// Both Old and New panes.
			await expect(preview.locator(".md-side")).toHaveCount(2);
			// Changed paragraph: removed tinted in Old, added tinted in New;
			// the added tail block is also green.
			await expect(preview.locator(".md-del")).toContainText("Old intro paragraph.");
			await expect(
				preview.locator(".md-ins").filter({ hasText: "New intro paragraph." }),
			).toBeVisible();
			await expect(
				preview.locator(".md-ins").filter({ hasText: "Brand new tail." }),
			).toBeVisible();
			// Rendered HTML, not source.
			await expect(preview.locator("h1").first()).toHaveText("README");
			// Diff body is gone while rendered.
			await expect(section.locator(".diff-content")).toHaveCount(0);

			await section.locator("button.md-view-toggle").click();
			await expect(section.locator(".diff-content")).toBeVisible();
			await expect(section.locator(".md-preview")).toHaveCount(0);
		} finally {
			await meerkat.kill();
		}
	});

	test("rendered view shows a badge when the file has line comments", async ({ page }) => {
		const meerkat = await startMeerkat({ fixture: modifiedMarkdownFixture() });
		try {
			await page.goto(meerkat.url);

			const section = page.locator(".file-section").filter({ hasText: "README.md" });

			// Add an inline comment on a new-side line in the diff.
			await section.locator("td.diff-line-new-num span[data-line-num]").first().click();
			const form = page.locator(".comment-form");
			await expect(form).toBeVisible();
			await form.locator("textarea").fill("a line comment");
			await form.getByRole("button", { name: /^Add Comment$/ }).click();
			await expect(form).toBeHidden();

			// Switching to rendered hides the line comment; the badge says so.
			await section.locator("button.md-view-toggle").click();
			await expect(section.locator(".md-preview")).toBeVisible();
			await expect(section.locator(".md-comments-hidden")).toContainText(
				"1 comment — switch to Diff",
			);
		} finally {
			await meerkat.kill();
		}
	});
});

import { type Page } from "@playwright/test";
import { expect, test } from "./lib/test";
import { startMeerkat } from "./lib/runner";

// The file-filter sidebar is closed by default (the diff body uses the
// full viewport width when no filter is active). Tests have to open it
// before touching `.file-filter` selectors. The toolbar button's
// accessible name is the aria-label `Toggle file list`; the visible
// "☰ Files" string is content, not the accessible name.
async function openFilesPanel(page: Page) {
	await page.getByRole("button", { name: /^Toggle file list$/ }).click();
	await expect(page.locator(".file-filter")).toBeVisible();
}

test.describe("file filter", () => {
	test("hide *.md hides NOTES.md; chip click restores it", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);
			await openFilesPanel(page);

			const notesHeader = page.getByRole("button", {
				name: /^▾ A NOTES\.md$/,
			});
			const rustHeader = page.getByRole("button", {
				name: /^▾ A src\/main\.rs$/,
			});
			await expect(notesHeader).toBeVisible();
			await expect(rustHeader).toBeVisible();

			// Hover the NOTES.md row in the file-filter list so the
			// "hide *.md" link surfaces, then click it.
			const filterRow = page.locator(".file-filter .file-entry").filter({
				has: page.locator(".base-name", { hasText: "NOTES.md" }),
			});
			await filterRow.hover();
			await filterRow.getByRole("button", { name: /^hide \*\.md$/ }).click();

			// NOTES.md vanishes; src/main.rs stays.
			await expect(notesHeader).toBeHidden();
			await expect(rustHeader).toBeVisible();

			// The hidden-extensions chip strip now shows .md.
			const mdChip = page.locator(".file-filter .filter-chip", {
				hasText: ".md",
			});
			await expect(mdChip).toBeVisible();

			// Clicking the chip restores the .md files.
			await mdChip.click();
			await expect(notesHeader).toBeVisible();
		} finally {
			await meerkat.kill();
		}
	});

	test("'only' button shows just one file", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);
			await openFilesPanel(page);

			// Both files visible to start.
			await expect(page.getByRole("button", { name: /^▾ A NOTES\.md$/ })).toBeVisible();
			await expect(page.getByRole("button", { name: /^▾ A src\/main\.rs$/ })).toBeVisible();

			// Click "only" on the rust row.
			const rustRow = page.locator(".file-filter .file-entry").filter({
				has: page.locator(".base-name", { hasText: "main.rs" }),
			});
			await rustRow.hover();
			await rustRow.getByRole("button", { name: /^only$/ }).click();

			// NOTES.md hidden, rust file remains.
			await expect(page.getByRole("button", { name: /^▾ A NOTES\.md$/ })).toBeHidden();
			await expect(page.getByRole("button", { name: /^▾ A src\/main\.rs$/ })).toBeVisible();
		} finally {
			await meerkat.kill();
		}
	});

	test("'Show all' restores both files after 'only'", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);
			await openFilesPanel(page);

			const notesHeader = page.getByRole("button", { name: /^▾ A NOTES\.md$/ });
			const rustHeader = page.getByRole("button", { name: /^▾ A src\/main\.rs$/ });
			await expect(notesHeader).toBeVisible();
			await expect(rustHeader).toBeVisible();

			// Pin rust file via "only".
			const rustRow = page.locator(".file-filter .file-entry").filter({
				has: page.locator(".base-name", { hasText: "main.rs" }),
			});
			await rustRow.hover();
			await rustRow.getByRole("button", { name: /^only$/ }).click();
			await expect(notesHeader).toBeHidden();

			// "Show all" must clear BOTH file_overrides AND only_file_index.
			// Bug regression: clearing only file_overrides left only_file_index
			// non-nil, so visible_indices/3's pinned-index short-circuit kept
			// every other file hidden.
			await page.getByRole("button", { name: /^Show all$/ }).click();
			await expect(notesHeader).toBeVisible();
			await expect(rustHeader).toBeVisible();
		} finally {
			await meerkat.kill();
		}
	});

	test("filter input narrows the list to matching files", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);
			await openFilesPanel(page);

			// Both rows present in the filter list to start.
			await expect(page.locator(".file-filter .base-name", { hasText: "NOTES.md" })).toBeVisible();
			await expect(page.locator(".file-filter .base-name", { hasText: "main.rs" })).toBeVisible();

			// Type "main" — non-matching entries are removed from the list
			// (FileFilter filters its `fileEntries` derivation, it does not
			// hide rows in place).
			await page.locator(".file-filter .filter-input").fill("main");
			await expect(page.locator(".file-filter .base-name", { hasText: "NOTES.md" })).toHaveCount(0);
			await expect(page.locator(".file-filter .base-name", { hasText: "main.rs" })).toBeVisible();

			// The toggle reflects the filter count: "Files (1 of 2)".
			await expect(page.getByRole("button", { name: /Files \(1 of 2\)/ })).toBeVisible();
		} finally {
			await meerkat.kill();
		}
	});
});

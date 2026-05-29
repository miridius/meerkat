import { expect, test } from "./lib/test";
import { startMeerkat } from "./lib/runner";

test.describe("smoke", () => {
	test("renders the page with header, files, and decision footer", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);
			await expect(page).toHaveTitle(/meerkat/i);

			// Both fixture files render — match the file-name button
			// text exactly to avoid colliding with diff body content.
			await expect(page.getByRole("button", { name: /^▾ A NOTES\.md$/ })).toBeVisible();
			await expect(page.getByRole("button", { name: /^▾ A src\/main\.rs$/ })).toBeVisible();

			// Commit-msg gutter shows one row per top-level block.
			// Subject = L1, body = L3-4, list items at L6 and L7.
			await expect(
				page.getByRole("button", {
					name: "Comment on commit message line 1",
				}),
			).toBeVisible();
			await expect(
				page.getByRole("button", {
					name: "Comment on commit message lines 3 through 4",
				}),
			).toBeVisible();
			await expect(
				page.getByRole("button", {
					name: "Comment on commit message line 6",
				}),
			).toBeVisible();
			await expect(
				page.getByRole("button", {
					name: "Comment on commit message line 7",
				}),
			).toBeVisible();

			// Decision footer.
			await expect(page.getByRole("button", { name: /^Approve$/ })).toBeVisible();
			await expect(page.getByRole("button", { name: /^Send Feedback$/ })).toBeVisible();
			await expect(page.getByRole("button", { name: /^Cancel$/ })).toBeVisible();
		} finally {
			await meerkat.kill();
		}
	});
});

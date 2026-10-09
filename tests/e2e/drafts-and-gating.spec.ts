import { expect, test } from "./lib/test";
import { startMeerkat } from "./lib/runner";

// Drafts are localStorage keys scoped to the URL's origin and keyed by
// review_id. A reload re-reads the draft; submitting clears it, and a
// decision wipes the review's drafts. Each startMeerkat() call uses a
// fresh temporary fixture repo and --port 0, so tests do not share
// drafts. Button gating on a dirty form and the Approve relabel are
// covered by the LiveView tests.
test.describe("comment drafts", () => {
	test("typed text gates the decision, survives a reload, is cleared by submitting, and a decision wipes the review's drafts", async ({
		page,
		context,
	}) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);
			const approve = page.getByRole("button", { name: /^Approve$/ });
			const sendFeedback = page.getByRole("button", { name: /^Send Feedback$/ });
			await expect(approve).toBeEnabled();

			// Open the global comment form, type, but do NOT submit.
			await page.getByRole("button", { name: /^\+ Add global comment$/ }).click();
			const form = page.locator(".comment-form");
			await form.locator("textarea").fill("draft body that should persist");
			await expect(approve, "unsaved text disables Approve").toBeDisabled();
			await expect(sendFeedback, "unsaved text disables Send Feedback").toBeDisabled();

			await page.reload();

			// `open_forms` is persisted server-side, so the form is already
			// open after reload. The body is restored from localStorage via
			// `loadFormDraft(draftKey)` in CommentForm.svelte's onMount.
			await expect(form).toBeVisible();
			await expect(form.locator("textarea")).toHaveValue("draft body that should persist");

			await form.getByRole("button", { name: /^Cancel$/ }).click();
			await expect(form).toBeHidden();
			await expect(approve, "discarding the form re-enables Approve").toBeEnabled();

			await page.getByRole("button", { name: /^\+ Add global comment$/ }).click();
			await form.locator("textarea").fill("submit then reload");
			await form.getByRole("button", { name: /^Issue$/ }).click();
			await form.getByRole("button", { name: /^Add Global Comment$/ }).click();
			await expect(form).toBeHidden();

			await page.reload();
			await expect(form, "a submitted form does not reopen on reload").toBeHidden();
			await page.getByRole("button", { name: /^\+ Add another$/ }).click();
			await expect(form.locator("textarea"), "submitting cleared the draft").toHaveValue("");

			await form.locator("textarea").fill("typed before the decision");
			const draftKeys = (p: typeof page) =>
				p.evaluate(() => Object.keys(localStorage).filter((k) => k.startsWith("meerkat:draft:")));
			await expect.poll(() => draftKeys(page)).toHaveLength(1);

			await page.locator("button.cancel-btn").click();
			await expect(page.getByRole("heading", { name: /^Cancelled$/ })).toBeVisible();

			// The done view closes its own tab, so read the shared storage from another.
			const other = await context.newPage();
			await other.goto(meerkat.url);
			await expect.poll(() => draftKeys(other)).toEqual([]);
		} finally {
			await meerkat.kill();
		}
	});
});

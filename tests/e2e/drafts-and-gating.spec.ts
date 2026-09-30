import { expect, test } from "./lib/test";
import { startMeerkat } from "./lib/runner";

// Drafts use localStorage scoped to the review URL's origin (the
// random port). Reload (within the same meerkat invocation) re-reads
// the draft. A fresh meerkat invocation gets a different port and a
// fresh review_id, so drafts do NOT persist across invocations; the
// test exercises the same-invocation reload path only. How the view
// gates the decision buttons on a dirty form, and relabels Approve, is
// covered by the LiveView tests.
test.describe("comment drafts", () => {
	test("typed text gates the decision, survives a reload, and is cleared by submitting", async ({
		page,
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
		} finally {
			await meerkat.kill();
		}
	});
});

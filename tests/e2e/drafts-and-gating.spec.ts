import { expect, test } from "./lib/test";
import { startMeerkat } from "./lib/runner";

// Drafts use localStorage scoped to the review URL's origin (the
// random port). Reload (within the same meerkat invocation) re-reads
// the draft. A fresh meerkat invocation gets a different port and a
// fresh review_id, so drafts do NOT persist across invocations — the
// test exercises the same-invocation reload path only.
test.describe("draft persistence", () => {
	test("typed text in a global comment form survives a page reload", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			// Open the global comment form, type, but do NOT submit.
			await page.getByRole("button", { name: /^\+ Add global comment$/ }).click();
			const form = page.locator(".comment-form");
			await form.locator("textarea").fill("draft body that should persist");

			await page.reload();

			// `open_form` is now persisted server-side, so the form is
			// already open after reload — no re-click needed. The body
			// is restored from localStorage via `loadFormDraft(draftKey)`
			// in CommentForm.svelte's onMount.
			const restoredForm = page.locator(".comment-form");
			await expect(restoredForm).toBeVisible();
			await expect(restoredForm.locator("textarea")).toHaveValue("draft body that should persist");
		} finally {
			await meerkat.kill();
		}
	});

	test("submitting clears the draft for that key", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			await page.getByRole("button", { name: /^\+ Add global comment$/ }).click();
			const form = page.locator(".comment-form");
			await form.locator("textarea").fill("submit then reload");
			await form.getByRole("button", { name: /^Issue$/ }).click();
			await form.getByRole("button", { name: /^Add Global Comment$/ }).click();
			await expect(form).toBeHidden();

			// After submit, reload — the form should NOT auto-open with
			// the submitted text.
			await page.reload();
			await expect(page.locator(".comment-form")).toBeHidden();
		} finally {
			await meerkat.kill();
		}
	});
});

test.describe("dirty-form gating", () => {
	test("Approve and Send Feedback are disabled while a comment form has unsaved text", async ({
		page,
	}) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			// Both buttons start enabled (Approve enabled, Send Feedback
			// only enabled with feedback — disabled with no comments).
			await expect(page.getByRole("button", { name: /^Approve$/ })).toBeEnabled();
			await expect(page.getByRole("button", { name: /^Send Feedback$/ })).toBeDisabled(); // no feedback yet

			// Open a global form, type something — this flips dirtyFormCount.
			await page.getByRole("button", { name: /^\+ Add global comment$/ }).click();
			const form = page.locator(".comment-form");
			await form.locator("textarea").fill("unsaved draft");

			// Both decision buttons are now disabled with a tooltip
			// telling the user to add or discard the open comment.
			await expect(page.getByRole("button", { name: /^Approve$/ })).toBeDisabled();
			await expect(page.getByRole("button", { name: /^Send Feedback$/ })).toBeDisabled();

			// Discard via Cancel → buttons re-enable.
			await form.getByRole("button", { name: /^Cancel$/ }).click();
			await expect(form).toBeHidden();
			await expect(page.getByRole("button", { name: /^Approve$/ })).toBeEnabled();
		} finally {
			await meerkat.kill();
		}
	});

	test("Approve label flips to 'Approve with feedback' once a comment exists", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			// Bare Approve button to start.
			await expect(page.getByRole("button", { name: /^Approve$/ })).toBeVisible();

			// Add a global comment.
			await page.getByRole("button", { name: /^\+ Add global comment$/ }).click();
			const form = page.locator(".comment-form");
			await form.locator("textarea").fill("just a follow-up");
			await form.getByRole("button", { name: /^Follow-up$/ }).click();
			await form.getByRole("button", { name: /^Add Global Comment$/ }).click();
			await expect(form).toBeHidden();

			// Label flipped.
			await expect(page.getByRole("button", { name: /^Approve with feedback$/ })).toBeVisible();
			// And Send Feedback is enabled now.
			await expect(page.getByRole("button", { name: /^Send Feedback$/ })).toBeEnabled();
		} finally {
			await meerkat.kill();
		}
	});
});

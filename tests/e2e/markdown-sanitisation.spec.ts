import { expect, test } from "./lib/test";
import { startMeerkat } from "./lib/runner";

// Comments are rendered server-side via marked + DOMPurify (or
// equivalent). This spec covers the documented contract that the
// XSS-prevention path actually runs — a comment body containing a
// <script> tag should NOT execute, and the rendered HTML should not
// contain it as an active element.

test.describe("markdown rendering / sanitisation", () => {
	test("a comment with <script> in the body does NOT execute the script", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			let alertFired = false;
			page.on("dialog", async (dialog) => {
				alertFired = true;
				await dialog.dismiss();
			});

			await page.goto(meerkat.url);

			await page.getByRole("button", { name: /^\+ Add global comment$/ }).click();
			const form = page.locator(".comment-form");
			await form.locator("textarea").fill('hello <script>alert("xss")</script> world');
			await form.getByRole("button", { name: /^Issue$/ }).click();
			await form.getByRole("button", { name: /^Add Global Comment$/ }).click();
			await expect(form).toBeHidden();

			// Body text still includes the literal text, but the
			// script tag never ran (no alert dialog).
			const card = page.locator(".global-comments .note").first();
			await expect(card).toContainText("hello");
			await expect(card).toContainText("world");
			expect(alertFired).toBe(false);

			// And the rendered HTML does NOT contain a live <script>
			// element.
			expect(await card.locator("script").count()).toBe(0);
		} finally {
			await meerkat.kill();
		}
	});

	test("standard markdown — bold, code, list — renders to its HTML form", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			await page.getByRole("button", { name: /^\+ Add global comment$/ }).click();
			const form = page.locator(".comment-form");
			await form.locator("textarea").fill("**bold** and `inline code`\n\n- item one\n- item two");
			await form.getByRole("button", { name: /^Follow-up$/ }).click();
			await form.getByRole("button", { name: /^Add Global Comment$/ }).click();
			await expect(form).toBeHidden();

			const card = page.locator(".global-comments .note").first();
			await expect(card.locator("strong")).toContainText("bold");
			await expect(card.locator("code")).toContainText("inline code");
			await expect(card.locator("ul li").first()).toContainText("item one");
			await expect(card.locator("ul li").nth(1)).toContainText("item two");
		} finally {
			await meerkat.kill();
		}
	});
});

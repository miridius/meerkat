import { type BrowserContext, type Page } from "@playwright/test";
import { expect, test } from "./lib/test";
import { startMeerkat } from "./lib/runner";

// Multi-tab consistency. `Meerkat.ReviewServer` owns the canonical
// review state and broadcasts every mutation over Phoenix.PubSub,
// so a comment added in one tab MUST appear in every other open
// tab on the same review_id without a reload.

test.describe("multi-tab consistency", () => {
	test("a global comment added in tab A appears in tab B without a reload", async ({
		context,
	}) => {
		const meerkat = await startMeerkat();
		try {
			const tabA = await context.newPage();
			const tabB = await context.newPage();
			await tabA.goto(meerkat.url);
			await tabB.goto(meerkat.url);

			await addGlobalComment(tabA, "comment from tab A");

			// Tab B sees the comment via the PubSub broadcast, no
			// explicit reload needed. The `auto-retry` semantics of
			// `toContainText` give us up to 5s — plenty for a
			// websocket round-trip.
			await expect(
				tabB.locator(".global-comments .note").filter({ hasText: "comment from tab A" }),
			).toBeVisible();
		} finally {
			await meerkat.kill();
		}
	});

	test("removing a comment in tab A removes it from tab B too", async ({ context }) => {
		const meerkat = await startMeerkat();
		try {
			const tabA = await context.newPage();
			const tabB = await context.newPage();
			await tabA.goto(meerkat.url);
			await tabB.goto(meerkat.url);

			await addGlobalComment(tabA, "to be removed");

			// Wait for tab B to see it before removing.
			await expect(
				tabB.locator(".global-comments .note").filter({ hasText: "to be removed" }),
			).toBeVisible();

			// Remove via tab A.
			await tabA
				.locator(".global-comments .note")
				.filter({ hasText: "to be removed" })
				.getByRole("button", { name: /^Remove$/ })
				.click();

			// Tab B sees the removal.
			await expect(
				tabB.locator(".global-comments .note").filter({ hasText: "to be removed" }),
			).toHaveCount(0);
		} finally {
			await meerkat.kill();
		}
	});
});

// Local helper — duplicates a similar fn in comments.spec.ts; kept
// inline to avoid a shared helpers module Playwright then has to be
// taught to exclude from test discovery.
async function addGlobalComment(page: Page, body: string) {
	await page.getByRole("button", { name: /^\+ Add global comment$/ }).click();
	const form = page.locator(".comment-form");
	await form.locator("textarea").fill(body);
	await form.getByRole("button", { name: /^Issue$/ }).click();
	await form.getByRole("button", { name: /^Add Global Comment$/ }).click();
	await expect(form).toBeHidden();
}

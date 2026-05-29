import { readFileSync } from "node:fs";
import { expect, test } from "./lib/test";
import { makePrFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";

test.describe("Post to GitHub from --pr mode", () => {
	test("submits a pending review via `gh api` and opens the returned URL in a new tab", async ({
		context,
		page,
	}) => {
		const fixture = makePrFixture({ prNumber: 456 });

		const meerkat = await startMeerkat({
			fixture,
			args: ["--pr", String(fixture.prNumber)],
			pathPrefixes: [fixture.ghStubDir],
		});
		try {
			await page.goto(meerkat.url);

			// Add a global comment so there's something to post.
			await page.getByRole("button", { name: /^\+ Add global comment$/ }).click();
			const form = page.locator(".comment-form");
			await form.locator("textarea").fill("looks good overall, one nit");
			await form.getByRole("button", { name: /^Follow-up$/ }).click();
			await form.getByRole("button", { name: /^Add Global Comment$/ }).click();
			await expect(form).toBeHidden();

			// "Post to GitHub" is only rendered in --pr mode.
			const postBtn = page.getByRole("button", { name: /^Post to GitHub$/ });
			await expect(postBtn).toBeVisible();

			// Clicking opens the returned URL in a new tab; capture it.
			const newPagePromise = context.waitForEvent("page");
			await postBtn.click();
			const newTab = await newPagePromise;
			expect(newTab.url()).toBe(fixture.reviewHtmlUrl);
			await newTab.close();

			// The gh stub captured the request body — verify the
			// comment we typed flows into the GitHub review payload.
			const captured = readFileSync(fixture.apiCapturePath, "utf-8");
			expect(captured).toContain("looks good overall, one nit");
		} finally {
			await meerkat.kill();
		}
	});
});

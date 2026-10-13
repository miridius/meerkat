import { expect, test } from "./lib/test";
import { startMeerkat } from "./lib/runner";

// The browser seam of the agent-instruction toggles on posted comments:
// the payload the browser sends, from LiveView's markup for global
// comments and from InlineComment.svelte for inline ones, must carry the
// flag's new value. LiveViewTest builds that payload itself, so it cannot
// reach this.

test("flags toggled on posted global and inline comments are saved", async ({ page }) => {
	const meerkat = await startMeerkat();
	try {
		await page.goto(meerkat.url);
		await page.getByRole("button", { name: /^\+ Add global comment$/ }).click();
		const globalForm = page.locator(".global-comments .comment-form");
		await globalForm.locator("textarea").fill("global text");
		await globalForm.getByRole("button", { name: /^Add Global Comment$/ }).click();

		// `src/main.rs` is an added file, so it renders unified.
		const file = page.locator(".file-section").filter({ hasText: "src/main.rs" });
		await file.locator('td.diff-line-num span[data-line-new-num="1"]').click();
		const inlineForm = file.locator(".comment-form");
		await inlineForm.locator("textarea").fill("inline text");
		await inlineForm.getByRole("button", { name: /^Add Comment$/ }).click();

		const global = page.locator(".global-comments .flag-toggle[data-flag=lint_rule] input");
		const toggles = [file.locator(".inline-comment .flag-toggle[data-flag=lint_rule] input"), global];
		// The socket delivers events in order, so once the server re-renders
		// the global toggle, which is toggled last, it has every toggle.
		const reloadOnceSaved = async (next: string) => {
			await expect(global).toHaveAttribute("phx-value-checked", next);
			await page.reload();
		};

		for (const toggle of toggles) await toggle.check();
		await reloadOnceSaved("false");
		for (const toggle of toggles) await expect(toggle, "a ticked flag survives a reload").toBeChecked();

		for (const toggle of toggles) await toggle.uncheck();
		await reloadOnceSaved("true");
		for (const toggle of toggles) await expect(toggle, "an unticked flag survives a reload").not.toBeChecked();
	} finally {
		await meerkat.kill();
	}
});

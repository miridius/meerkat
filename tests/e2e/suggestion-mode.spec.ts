import { expect, test } from "./lib/test";
import { startMeerkat } from "./lib/runner";

test.describe("suggestion-mode CodeMirror editor", () => {
	test("selecting Suggestion swaps the textarea for a prose+code split with a CodeMirror editor", async ({
		page,
	}) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			await page.getByRole("button", { name: /^\+ Add global comment$/ }).click();
			const form = page.locator(".comment-form");
			await expect(form).toBeVisible();

			// Plain mode renders a single textarea.
			await expect(form.locator("textarea")).toHaveCount(1);

			// Switch to Suggestion — the form re-renders with the
			// prose textarea on top and the code-host below. The
			// CodeMirror editor mounts inside `.code-host`.
			await form.getByRole("button", { name: /^Suggestion$/ }).click();

			await expect(form.locator(".code-host .cm-editor")).toBeVisible();
			// The split layout puts a prose textarea above the editor.
			await expect(form.locator("textarea.prose")).toBeVisible();
		} finally {
			await meerkat.kill();
		}
	});

	test("submitted suggestion body wraps the editor contents in a fenced code block", async ({
		page,
	}) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			await page.getByRole("button", { name: /^\+ Add global comment$/ }).click();
			const form = page.locator(".comment-form");
			await form.getByRole("button", { name: /^Suggestion$/ }).click();

			// Type the prose half.
			await form.locator("textarea.prose").fill("rename for clarity");

			// Type into the CodeMirror editor's contenteditable
			// surface. Click to focus first.
			const editor = form.locator(".code-host .cm-content");
			await editor.click();
			await page.keyboard.type("let renamed = 1;");

			// Submit. The composed body lands as a comment with a
			// fenced suggestion block.
			await form.getByRole("button", { name: /^Add Global Comment$/ }).click();
			await expect(form).toBeHidden();

			const card = page.locator(".global-comments .note").first();
			// Prose half renders as plain text in the body; code half
			// renders inside a `<pre><code>` fenced block. Asserting
			// both surfaces means the test fails if the composer
			// silently drops the fence (which is the regression risk —
			// without a fence, GitHub doesn't render a suggestion
			// block).
			await expect(card).toContainText("rename for clarity");
			const codeBlock = card.locator("pre code");
			await expect(codeBlock).toContainText("let renamed = 1;");
			// The prose line is NOT inside the code block.
			await expect(codeBlock).not.toContainText("rename for clarity");
		} finally {
			await meerkat.kill();
		}
	});
});

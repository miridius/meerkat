import type { Locator, Page } from "@playwright/test";
import { makeFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";
import { expect, test } from "./lib/test";

// The browser seam of the suggestion editor's hotkeys: real key presses
// reach the commands, and the Keys cheat sheet's Escape stays out of the
// form's. The commands themselves are covered by assets/ts/paredit.test.ts,
// syntaxEdit.test.ts and editorKeys.test.ts.

const CLJ = `(ns app.core)

(defn f [x]
  (let [y (inc x)]
    (foo y) bar))
`;

function newLine(fileSection: Locator, n: number): Locator {
	return fileSection.locator(`td.diff-line-num span[data-line-new-num="${n}"]`);
}

async function openSuggestion(page: Page, line: number): Promise<Locator> {
	const fileSection = page.locator(".file-section").filter({ hasText: "core.clj" });
	await newLine(fileSection, line).evaluate((el) => el.scrollIntoView({ block: "center" }));
	await newLine(fileSection, line).click();
	const form = fileSection.locator(`tr.meerkat-form-row[data-meerkat-form-anchor="${line}"] .comment-form`);
	await form.getByRole("button", { name: /^Suggestion$/ }).click();
	// The Clojure pack has joined once `foo` is highlighted as a call.
	await expect(form.locator(".code-host .cm-line span", { hasText: /^foo$/ })).toHaveCount(1);
	return form;
}

test("Clojure keys and structural typing work in a suggestion", async ({ page }) => {
	const meerkat = await startMeerkat({ fixture: makeFixture({ files: { "src/app/core.clj": CLJ } }) });
	try {
		await page.goto(meerkat.url);
		const form = await openSuggestion(page, 5);
		const line = form.locator(".code-host .cm-line");
		const text = () => line.evaluate((el) => el.textContent);
		await expect.poll(text).toBe("    (foo y) bar))");

		// Caret after `foo`: Home goes to the end of the indentation.
		await line.click();
		await page.keyboard.press("Home");
		for (let i = 0; i < 4; i++) await page.keyboard.press("ArrowRight");
		await page.keyboard.press("ControlOrMeta+Shift+K");
		await expect.poll(text).toBe("    (foo y bar)))");

		// Backspace steps over the matched `(`, rather than deleting it.
		await page.keyboard.press("Home");
		await page.keyboard.press("ArrowRight");
		await page.keyboard.press("Backspace");
		await page.keyboard.type("[");
		await expect.poll(text).toBe("    [](foo y bar)))");
	} finally {
		await meerkat.kill();
	}
});

test("Escape closes the Keys cheat sheet and leaves the form open", async ({ page }) => {
	const meerkat = await startMeerkat({ fixture: makeFixture({ files: { "src/app/core.clj": CLJ } }) });
	try {
		await page.goto(meerkat.url);
		const form = await openSuggestion(page, 5);
		await form.locator(".code-host .cm-line").click();
		await form.getByRole("button", { name: "Keys" }).click();
		const sheet = form.getByRole("dialog", { name: "Editor keys" });
		await expect(sheet).toContainText("Slurp / barf forward");
		await form.locator(".code-host .cm-content").focus();
		await page.keyboard.press("Escape");
		await expect(sheet).toHaveCount(0);
		await expect(form).toBeVisible();
	} finally {
		await meerkat.kill();
	}
});

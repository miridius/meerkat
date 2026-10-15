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

// The hotkeys bind on macOS only, which a test emulates on any system
// by setting the platform the page reads before its scripts load.
async function onPlatform(page: Page, platform: string): Promise<void> {
	await page.addInitScript((p) => {
		Object.defineProperty(Navigator.prototype, "platform", { get: () => p });
	}, platform);
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
		await onPlatform(page, "MacIntel");
		await page.goto(meerkat.url);
		const form = await openSuggestion(page, 5);
		const line = form.locator(".code-host .cm-line");
		const text = () => line.evaluate((el) => el.textContent);
		await expect.poll(text).toBe("    (foo y) bar))");

		// Caret after `foo`: Home goes to the end of the indentation.
		await line.click();
		await page.keyboard.press("Home");
		for (let i = 0; i < 4; i++) await page.keyboard.press("ArrowRight");
		await page.keyboard.press("Meta+Shift+K");
		await expect.poll(text).toBe("    (foo y bar)))");

		// Backspace steps over the matched `(`, rather than deleting it.
		await page.keyboard.press("Home");
		await page.keyboard.press("ArrowRight");
		await page.keyboard.press("Backspace");
		await page.keyboard.type("[");
		await expect.poll(text).toBe("    [](foo y bar)))");

		// Caret inside `(foo y bar)`: thread first, then unthread.
		await page.keyboard.press("Home");
		for (let i = 0; i < 3; i++) await page.keyboard.press("ArrowRight");
		await page.keyboard.press("Control+Alt+Comma");
		await expect.poll(text).toBe("    [](-> y (foo bar))))");
		await page.keyboard.press("Control+Alt+Period");
		await expect.poll(text).toBe("    [](foo y bar)))");

		// Unthreading left the caret before `(foo y bar)`.
		await page.keyboard.press("Meta+Shift+Digit9");
		await expect.poll(text).toBe("    []((foo y bar))))");
		await page.keyboard.press("Control+K");
		await expect.poll(text).toBe("    []()))");
	} finally {
		await meerkat.kill();
	}
});

test("off macOS the keys keep CodeMirror's bindings and the editor shows no Keys link", async ({ page }) => {
	const meerkat = await startMeerkat({ fixture: makeFixture({ files: { "src/app/core.clj": CLJ } }) });
	try {
		await onPlatform(page, "Linux x86_64");
		await page.goto(meerkat.url);
		const form = await openSuggestion(page, 5);
		const content = form.locator(".code-host .cm-content");
		await expect.poll(() => content.evaluate((el) => el.textContent)).toBe("    (foo y) bar))");
		await expect(form.getByRole("button", { name: "Keys" })).toHaveCount(0);
		// CodeMirror's Ctrl+Shift+K deletes the line, rather than slurping.
		await form.locator(".code-host .cm-line").click();
		await page.keyboard.press("Control+Shift+K");
		await expect.poll(() => content.evaluate((el) => el.textContent)).toBe("");
	} finally {
		await meerkat.kill();
	}
});

test("Escape closes the Keys cheat sheet and leaves the form open", async ({ page }) => {
	const meerkat = await startMeerkat({ fixture: makeFixture({ files: { "src/app/core.clj": CLJ } }) });
	try {
		await onPlatform(page, "MacIntel");
		await page.goto(meerkat.url);
		const form = await openSuggestion(page, 5);
		await form.locator(".code-host .cm-line").click();
		await form.getByRole("button", { name: "Keys" }).click();
		const sheet = form.getByRole("dialog", { name: "Editor keys" });
		await expect(sheet).toContainText("Slurp / barf forward");
		await form.locator(".code-host .cm-content").focus();
		await page.keyboard.press("Escape");
		await expect(sheet).toHaveCount(0);

		// A click outside closes it too.
		await form.getByRole("button", { name: "Keys" }).click();
		await expect(sheet).toBeVisible();
		await form.locator(".code-host .cm-line").click();
		await expect(sheet).toHaveCount(0);

		// The server handles events in order, so once a form opened on
		// another line shows, a cancel the Escape sent would have closed
		// this one.
		const fileSection = page.locator(".file-section").filter({ hasText: "core.clj" });
		await newLine(fileSection, 3).click();
		await expect(fileSection.locator('tr.meerkat-form-row[data-meerkat-form-anchor="3"] .comment-form')).toBeVisible();
		await expect(form).toBeVisible();

		// Leaving the suggestion type by keyboard closes the sheet, so
		// Escape cancels the form again.
		await form.getByRole("button", { name: "Keys" }).click();
		await expect(sheet).toBeVisible();
		await form.getByRole("button", { name: /^Issue$/ }).focus();
		await page.keyboard.press("Space");
		await form.locator("textarea").focus();
		await page.keyboard.press("Escape");
		await expect(form).toHaveCount(0);
	} finally {
		await meerkat.kill();
	}
});

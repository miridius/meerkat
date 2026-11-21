import { chmodSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Locator, Page } from "@playwright/test";
import { makeFixture, ownedTmpDir } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";
import { expect, test } from "./lib/test";

// The browser seams of a Clojure suggestion: real key presses reach the
// editor's hotkeys, the Keys cheat sheet's Escape stays out of the form's,
// DiffViewer.svelte hands the editor the file's text above the anchored
// lines for indenting, and CommentForm.svelte sends the suggestion as it
// looks in the editor, with its language, for the server's formatter hook.
// The commands and the macOS-only binding are covered by
// assets/ts/paredit.test.ts, syntaxEdit.test.ts and editorKeys.test.ts, and
// the editor off macOS by clj-hover.spec.ts; the
// indent rules by cmIndent.test.ts and clojureIndent.test.ts; the
// formatting by test/meerkat_web/live/review_live_comments_test.exs.

const KEYS_CLJ = `(ns app.core)

(defn f [x]
  (let [y (inc x)]
    (foo y) bar))
`;

const INDENT_CLJ = `(ns demo.core)

(defn handler [req]
  (let [x (:x req)
        y 2]
    (when (pos? x)
      (println "x" x))))
`;

function newLine(fileSection: Locator, n: number): Locator {
	return fileSection.locator(`td.diff-line-num span[data-line-new-num="${n}"]`);
}

function formAt(fileSection: Locator, n: number): Locator {
	return fileSection.locator(`tr.meerkat-form-row[data-meerkat-form-anchor="${n}"] .comment-form`);
}

async function dragLines(page: Page, fileSection: Locator, from: number, to: number) {
	await newLine(fileSection, to).evaluate((el) => el.scrollIntoView({ block: "center" }));
	const a = await newLine(fileSection, from).boundingBox();
	const b = await newLine(fileSection, to).boundingBox();
	if (!a || !b) throw new Error("gutter lines not found");
	await page.mouse.move(a.x + a.width / 2, a.y + a.height / 2);
	await page.mouse.down();
	await page.mouse.move(b.x + b.width / 2, b.y + b.height / 2, { steps: 5 });
	await page.mouse.up();
}

test("in a Clojure suggestion, the hotkeys and structural typing work, the Keys sheet's Escape leaves the form open, Enter indents as in the file, and a save sends the text as shown through the formatter hook", async ({
	page,
}) => {
	// A hook whose cljfmt pass widens the space in `(pos? x)` to three,
	// which the save keeps.
	const hookDir = ownedTmpDir("meerkat-e2e");
	try {
		const hook = join(hookDir, "clj-paren-repair-claude-hook");
		writeFileSync(
			hook,
			`#!/bin/sh
file=$(sed 's/.*"file_path":"\\([^"]*\\)".*/\\1/')
if [ "$2" = --cljfmt ]; then
  sed 's/(pos? x)/(pos?   x)/' "$file" > "$file.new" && mv "$file.new" "$file"
fi
`,
		);
		chmodSync(hook, 0o755);
		const meerkat = await startMeerkat({
			fixture: makeFixture({ files: { "src/app/core.clj": KEYS_CLJ, "src/demo/core.clj": INDENT_CLJ } }),
			pathPrefixes: [hookDir],
		});
		try {
			// The hotkeys bind on macOS only, which the test emulates on any
			// system by setting the platform the page reads before its
			// scripts load.
			await page.addInitScript(() => {
				Object.defineProperty(Navigator.prototype, "platform", { get: () => "MacIntel" });
			});
			await page.goto(meerkat.url);
			const app = page.locator(".file-section").filter({ hasText: "src/app/core.clj" });
			const demo = page.locator(".file-section").filter({ hasText: "src/demo/core.clj" });

			const form = formAt(app, 5);
			await test.step("the hotkeys reach their commands", async () => {
				await newLine(app, 5).evaluate((el) => el.scrollIntoView({ block: "center" }));
				await newLine(app, 5).click();
				await form.getByRole("button", { name: /^Suggestion$/ }).click();
				// The Clojure pack has joined once `foo` is highlighted as a call.
				await expect(form.locator(".code-host .cm-line span", { hasText: /^foo$/ })).toHaveCount(1);
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

				// Caret before `y`, the first argument: thread first, then step
				// inside the thread and unthread.
				await page.keyboard.press("Home");
				for (let i = 0; i < 7; i++) await page.keyboard.press("ArrowRight");
				await page.keyboard.press("Control+Alt+Comma");
				await expect.poll(text).toBe("    [](-> y (foo bar))))");
				await page.keyboard.press("ArrowRight");
				await page.keyboard.press("Control+Alt+Period");
				await expect.poll(text).toBe("    [](foo y bar)))");

				// Unthreading left the caret before `(foo y bar)`.
				await page.keyboard.press("Meta+Shift+Digit9");
				await expect.poll(text).toBe("    []((foo y bar))))");
				await page.keyboard.press("Control+K");
				await expect.poll(text).toBe("    []()))");
			});

			await test.step("Escape closes the Keys cheat sheet and leaves the form open", async () => {
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
				await newLine(app, 3).click();
				await expect(formAt(app, 3)).toBeVisible();
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
			});

			await test.step("Enter on lines inside a form indents as in the file", async () => {
				await dragLines(page, demo, 5, 6);
				const indented = formAt(demo, 6);
				await indented.getByRole("button", { name: /^Suggestion$/ }).click();
				const lines = indented.locator(".code-host .cm-line");
				await expect(lines).toHaveCount(2);
				// The Clojure pack has joined once `when` is highlighted.
				await expect(lines.locator("span", { hasText: /^when$/ })).toHaveCount(1);

				await lines.first().click();
				await page.keyboard.press("End");
				await page.keyboard.press("Enter");
				// Four spaces, the let's body, whose opener sits above the editor's
				// lines: alone, `y 2]` closes nothing. toHaveText would collapse the
				// spaces.
				await expect.poll(() => lines.nth(1).evaluate((el) => el.textContent)).toBe(" ".repeat(4));
				await indented.getByRole("button", { name: /^Cancel$/ }).click();
				await expect(indented).toHaveCount(0);
			});

			await test.step("a save sends the suggestion as shown and runs the formatter hook", async () => {
				await dragLines(page, demo, 4, 6);
				const saved = formAt(demo, 6);
				await saved.getByRole("button", { name: /^Suggestion$/ }).click();
				const lines = saved.locator(".code-host .cm-line");
				await expect(lines).toHaveCount(3);
				await expect(lines.locator("span", { hasText: /^when$/ })).toHaveCount(1);
				// `let` to `if-let` moves `[` past the binding below it.
				await lines.first().click();
				await page.keyboard.press("Home");
				await page.keyboard.press("ArrowRight");
				await page.keyboard.type("if-");
				await expect(lines.first()).toHaveText("  (if-let [x (:x req)");
				// Without the `]`, re-indenting the lines by their brackets would
				// put the body in the bindings, so the save must send them as
				// shown. The hook stand-in repairs nothing, so the save shows what
				// was sent, with its cljfmt widening.
				await lines.nth(1).click();
				await page.keyboard.press("End");
				await page.keyboard.press("Shift+ArrowLeft");
				await page.keyboard.press("Backspace");
				await saved.getByRole("button", { name: "Add Comment" }).click();
				await expect(
					demo.locator(".inline-comment pre code span", { hasText: /^when$/ }),
					"the suggestion is coloured as the diff colours Clojure",
				).toHaveCSS("color", "rgb(249, 117, 131)");
				// After highlighting, which must keep the whitespace.
				await expect
					.poll(() => demo.locator(".inline-comment pre").first().evaluate((el) => el.textContent))
					.toBe("  (if-let [x (:x req)\n           y 2\n    (when (pos?   x)\n");
			});
		} finally {
			await meerkat.kill();
		}
	} finally {
		rmSync(hookDir, { recursive: true, force: true });
	}
});

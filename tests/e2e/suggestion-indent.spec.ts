import { chmodSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Locator, Page } from "@playwright/test";
import { makeFixture, ownedTmpDir } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";
import { expect, test } from "./lib/test";

// The browser seams of a Clojure suggestion. Indentation: DiffViewer.svelte
// hands the editor the file's text above the anchored lines. The rules
// themselves are covered by assets/ts/cmIndent.test.ts and
// assets/ts/clojureIndent.test.ts.

const CLJ = `(ns demo.core)

(defn handler [req]
  (let [x (:x req)
        y 2]
    (when (pos? x)
      (println "x" x))))
`;

function newLine(fileSection: Locator, n: number): Locator {
	return fileSection.locator(`td.diff-line-num span[data-line-new-num="${n}"]`);
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

test("Enter in a Clojure suggestion on lines inside a form indents as in the file", async ({ page }) => {
	const meerkat = await startMeerkat({ fixture: makeFixture({ files: { "src/demo/core.clj": CLJ } }) });
	try {
		await page.goto(meerkat.url);
		const fileSection = page.locator(".file-section").filter({ hasText: "core.clj" });
		await dragLines(page, fileSection, 5, 6);
		const form = fileSection.locator('tr.meerkat-form-row[data-meerkat-form-anchor="6"] .comment-form');
		await form.getByRole("button", { name: /^Suggestion$/ }).click();
		const lines = form.locator(".code-host .cm-line");
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
	} finally {
		await meerkat.kill();
	}
});

// The browser seam of formatting on save: CommentForm.svelte sends the
// editor's language, and the server formats only a Clojure suggestion.
// The formatting is covered by test/meerkat_web/live/review_live_comments_test.exs.
test("saving a Clojure suggestion runs the formatter hook", async ({ page }) => {
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
			fixture: makeFixture({ files: { "src/demo/core.clj": CLJ } }),
			pathPrefixes: [hookDir],
		});
		try {
			await page.goto(meerkat.url);
			const fileSection = page.locator(".file-section").filter({ hasText: "core.clj" });
			await dragLines(page, fileSection, 5, 6);
			const form = fileSection.locator('tr.meerkat-form-row[data-meerkat-form-anchor="6"] .comment-form');
			await form.getByRole("button", { name: /^Suggestion$/ }).click();
			await expect(form.locator(".code-host .cm-line")).toHaveCount(2);
			await form.getByRole("button", { name: "Add Comment" }).click();
			await expect
				.poll(() => fileSection.locator(".inline-comment pre").first().evaluate((el) => el.textContent))
				.toContain("(pos?   x)");
		} finally {
			await meerkat.kill();
		}
	} finally {
		rmSync(hookDir, { recursive: true, force: true });
	}
});

import type { Locator, Page } from "@playwright/test";
import { makeFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";
import { expect, test } from "./lib/test";

// The browser seam of the suggestion editor's indentation: DiffViewer.svelte
// hands the editor the file's text around the anchored lines. The rules
// themselves are covered by assets/ts/cmIndent.test.ts and
// assets/ts/clojureIndent.test.ts.

const PY = `class A:
    def f(self, x):
        if x:
            y = x + 1
            return y
        return 0
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

test("Enter in a suggestion on lines inside a function indents as in the file", async ({ page }) => {
	const meerkat = await startMeerkat({ fixture: makeFixture({ files: { "app.py": PY } }) });
	try {
		await page.goto(meerkat.url);
		const fileSection = page.locator(".file-section").filter({ hasText: "app.py" });
		await dragLines(page, fileSection, 4, 5);
		const form = fileSection.locator('tr.meerkat-form-row[data-meerkat-form-anchor="5"] .comment-form');
		await form.getByRole("button", { name: /^Suggestion$/ }).click();
		const lines = form.locator(".code-host .cm-line");
		await expect(lines).toHaveCount(2);
		// The Python pack has joined once `return` is highlighted.
		await expect(lines.locator("span", { hasText: /^return$/ })).toHaveCount(1);

		await lines.first().click();
		await page.keyboard.press("End");
		await page.keyboard.press("Enter");
		// Twelve spaces, as in the file's `if` body: alone, the lines read
		// as top-level code, and CodeMirror's unit is two spaces, not four.
		// toHaveText would collapse the spaces.
		await expect.poll(() => lines.nth(1).evaluate((el) => el.textContent)).toBe(" ".repeat(12));
	} finally {
		await meerkat.kill();
	}
});

import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { type Locator, type Page } from "@playwright/test";
import { expect, test } from "./lib/test";
import { makeFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";

// `src/main.rs` is an added file, so it renders in unified mode with
// one `data-line-new-num` span per line.
function newLine(fileSection: Locator, n: number): Locator {
	return fileSection.locator(`td.diff-line-num span[data-line-new-num="${n}"]`);
}

function formAt(fileSection: Locator, endLine: number): Locator {
	return fileSection.locator(
		`tr.meerkat-form-row[data-meerkat-form-anchor="${endLine}"] .comment-form`,
	);
}

function commentRowAt(fileSection: Locator, endLine: number): Locator {
	return fileSection.locator(`tr.meerkat-comment-row[data-meerkat-anchor-line="${endLine}"]`);
}

// Drag on the gutter from line `from` to line `to`, the way a reviewer
// selects a range.
async function dragLines(page: Page, fileSection: Locator, from: number, to: number) {
	// Centre the range so the sticky footer can't cover either end.
	await newLine(fileSection, to).evaluate((el) => el.scrollIntoView({ block: "center" }));
	const a = await newLine(fileSection, from).boundingBox();
	const b = await newLine(fileSection, to).boundingBox();
	if (!a || !b) throw new Error("gutter lines not found");
	await page.mouse.move(a.x + a.width / 2, a.y + a.height / 2);
	await page.mouse.down();
	await page.mouse.move(b.x + b.width / 2, b.y + b.height / 2, { steps: 5 });
	await page.mouse.up();
}

function mainRs(page: Page): Locator {
	return page.locator(".file-section").filter({ hasText: "src/main.rs" });
}

test.describe("multiple open comment forms", () => {
	test("dragging a second range keeps the first form, and each posts at its own lines", async ({
		page,
	}) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);
			const fileSection = mainRs(page);

			await newLine(fileSection, 1).click();
			const first = formAt(fileSection, 1);
			await expect(first).toBeVisible();
			await first.locator("textarea").fill("comment for line 1");

			await dragLines(page, fileSection, 3, 5);
			const second = formAt(fileSection, 5);
			await expect(second).toBeVisible();
			await expect(first).toBeVisible();
			await expect(first.locator("textarea")).toHaveValue("comment for line 1");
			await second.locator("textarea").fill("comment for lines 3-5");

			await first.getByRole("button", { name: /^Add Comment$/ }).click();
			await expect(first).toBeHidden();
			await expect(commentRowAt(fileSection, 1)).toContainText("comment for line 1");
			await expect(commentRowAt(fileSection, 1)).toContainText("L1 (new)");
			await expect(commentRowAt(fileSection, 5)).toHaveCount(0);
			await expect(second.locator("textarea")).toHaveValue("comment for lines 3-5");

			await second.getByRole("button", { name: /^Add Comment$/ }).click();
			await expect(second).toBeHidden();
			await expect(commentRowAt(fileSection, 5)).toContainText("comment for lines 3-5");
			await expect(commentRowAt(fileSection, 5)).toContainText("L3–5 (new)");
			await expect(commentRowAt(fileSection, 1)).not.toContainText("comment for lines 3-5");
		} finally {
			await meerkat.kill();
		}
	});

	test("cancelling one form leaves the other open with its text", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);
			const fileSection = mainRs(page);

			await newLine(fileSection, 2).click();
			const first = formAt(fileSection, 2);
			await first.locator("textarea").fill("keep me");
			await newLine(fileSection, 6).click();
			const second = formAt(fileSection, 6);
			await expect(second).toBeVisible();

			await second.getByRole("button", { name: /^Cancel$/ }).click();
			await expect(second).toBeHidden();
			await expect(first.locator("textarea")).toHaveValue("keep me");

			// The unsaved-form gate still holds while one form is open.
			await expect(page.getByRole("button", { name: /^Approve$/ })).toBeDisabled();
			await first.getByRole("button", { name: /^Cancel$/ }).click();
			await expect(first).toBeHidden();
			await expect(page.getByRole("button", { name: /^Approve$/ })).toBeEnabled();
		} finally {
			await meerkat.kill();
		}
	});

	test("every open form and its draft survive a reload", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);
			const fileSection = mainRs(page);

			await newLine(fileSection, 1).click();
			await formAt(fileSection, 1).locator("textarea").fill("draft one");
			await newLine(fileSection, 4).click();
			await formAt(fileSection, 4).locator("textarea").fill("draft four");

			await page.reload();

			await expect(formAt(fileSection, 1).locator("textarea")).toHaveValue("draft one");
			await expect(formAt(fileSection, 4).locator("textarea")).toHaveValue("draft four");
		} finally {
			await meerkat.kill();
		}
	});

	test("open forms survive toggling between split and unified", async ({ page }) => {
		const fixture = makeFixture({ files: { "src/lib.rs": "fn a() {}\nfn b() {}\nfn c() {}\n" } });
		fixture.git("commit", "-q", "-m", "base");
		writeFileSync(join(fixture.dir, "src/lib.rs"), "fn a() {}\nfn b2() {}\nfn c() {}\nfn d() {}\n");
		fixture.git("add", "src/lib.rs");

		const meerkat = await startMeerkat({ fixture });
		try {
			await page.goto(meerkat.url);
			const fileSection = page.locator(".file-section").filter({ hasText: "src/lib.rs" });
			const forms = fileSection.locator("tr.meerkat-form-row .comment-form");

			await fileSection.locator('td.diff-line-new-num:has(span[data-line-num="1"])').click();
			await fileSection.locator('td.diff-line-new-num:has(span[data-line-num="4"])').click();
			await expect(forms).toHaveCount(2);
			await forms.nth(0).locator("textarea").fill("first draft");
			await forms.nth(1).locator("textarea").fill("second draft");

			for (const mode of ["Unified", "Split"]) {
				await page.getByRole("button", { name: mode, exact: true }).click();
				await expect(forms).toHaveCount(2);
				await expect(forms.nth(0).locator("textarea")).toHaveValue("first draft");
				await expect(forms.nth(1).locator("textarea")).toHaveValue("second draft");
			}

			await forms.nth(1).getByRole("button", { name: /^Add Comment$/ }).click();
			await expect(commentRowAt(fileSection, 4)).toContainText("second draft");

			// The posted comment and the form still open both survive a toggle too.
			await page.getByRole("button", { name: "Unified", exact: true }).click();
			await expect(commentRowAt(fileSection, 4)).toContainText("second draft");
			await expect(forms).toHaveCount(1);
			await expect(forms.nth(0).locator("textarea")).toHaveValue("first draft");
		} finally {
			await meerkat.kill();
		}
	});

	test("a global form and an inline form stay open together", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);
			const fileSection = mainRs(page);

			await newLine(fileSection, 3).click();
			const inline = formAt(fileSection, 3);
			await inline.locator("textarea").fill("inline text");

			await page.getByRole("button", { name: /^\+ Add global comment$/ }).click();
			const global = page.locator(".global-comments .comment-form");
			await global.locator("textarea").fill("global text");
			await expect(inline.locator("textarea")).toHaveValue("inline text");

			await global.getByRole("button", { name: /^Add Global Comment$/ }).click();
			await expect(page.locator(".global-comments .note")).toContainText("global text");
			await expect(inline.locator("textarea")).toHaveValue("inline text");

			await inline.getByRole("button", { name: /^Add Comment$/ }).click();
			await expect(commentRowAt(fileSection, 3)).toContainText("inline text");
			await expect(page.locator(".comment-form")).toHaveCount(0);
		} finally {
			await meerkat.kill();
		}
	});
});

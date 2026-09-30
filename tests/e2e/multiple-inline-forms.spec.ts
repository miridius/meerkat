import { writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Locator, Page } from "@playwright/test";
import { expect, test } from "./lib/test";
import { makeFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";

// The browser seam of several open comment forms: DiffViewer.svelte
// mounts each form as its own table row and must keep every mounted
// form's draft, finding type and learn flag while others open, close and
// post, and while the diff re-renders. Which forms are open, the footer
// that lists them, and closing an edit form when its comment is removed
// are covered by the LiveView and ReviewServer tests.

// Unified mode renders one `data-line-new-num` span per new-side line.
function newLine(fileSection: Locator, n: number): Locator {
	return fileSection.locator(`td.diff-line-num span[data-line-new-num="${n}"]`);
}

// Split mode's new-side gutter cell for line `n`.
function splitNewLine(fileSection: Locator, n: number): Locator {
	return fileSection.locator(`td.diff-line-new-num:has(span[data-line-num="${n}"])`);
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

test.describe("multiple open comment forms", () => {
	test("inline forms opened by click and drag keep each other's drafts, post at their own lines, and sit apart from an edit form at the same line", async ({
		page,
	}) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);
			// `src/main.rs` is an added file, so it renders unified.
			const fileSection = page.locator(".file-section").filter({ hasText: "src/main.rs" });
			// Labelled "Approve" or, once comments exist, with feedback.
			const approve = page.locator("button.approve-btn");

			await newLine(fileSection, 1).click();
			const first = formAt(fileSection, 1);
			await expect(first).toBeVisible();
			await first.locator("textarea").fill("comment for line 1");

			await dragLines(page, fileSection, 3, 5);
			const second = formAt(fileSection, 5);
			await expect(second).toBeVisible();
			await expect(first.locator("textarea")).toHaveValue("comment for line 1");
			await second.locator("textarea").fill("comment for lines 3-5");

			// Cancelling one form leaves the others and their text.
			await newLine(fileSection, 6).click();
			const third = formAt(fileSection, 6);
			await expect(third).toBeVisible();
			await third.getByRole("button", { name: /^Cancel$/ }).click();
			await expect(third).toBeHidden();
			await expect(first.locator("textarea")).toHaveValue("comment for line 1");
			await expect(second.locator("textarea")).toHaveValue("comment for lines 3-5");

			// A global form posting leaves the inline drafts alone.
			await page.getByRole("button", { name: /^\+ Add global comment$/ }).click();
			const global = page.locator(".global-comments .comment-form");
			await global.locator("textarea").fill("global text");
			await global.getByRole("button", { name: /^Add Global Comment$/ }).click();
			await expect(page.locator(".global-comments .note")).toContainText("global text");
			await expect(first.locator("textarea")).toHaveValue("comment for line 1");

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

			// An add form and an edit form at the same line: anchor row, then
			// the comment row, then the add form, then the edit form opened
			// after it.
			await newLine(fileSection, 7).click();
			await formAt(fileSection, 7).locator("textarea").fill("alpha");
			await formAt(fileSection, 7).getByRole("button", { name: /^Add Comment$/ }).click();
			await expect(commentRowAt(fileSection, 7)).toContainText("alpha");

			await newLine(fileSection, 7).click();
			await formAt(fileSection, 7).locator("textarea").fill("gamma");
			await commentRowAt(fileSection, 7).getByRole("button", { name: "Edit" }).click();
			await expect(formAt(fileSection, 7)).toHaveCount(2);

			const comment = 'tr.meerkat-comment-row[data-meerkat-anchor-line="7"]';
			const addForm = fileSection.locator(`${comment} + tr.meerkat-form-row textarea`);
			const editRow = fileSection.locator(`${comment} + tr.meerkat-form-row + tr.meerkat-form-row`);
			await expect(addForm).toHaveValue("gamma");
			await expect(editRow.locator("textarea")).toHaveValue("alpha");

			await editRow.locator("textarea").fill("beta");
			await editRow.getByRole("button", { name: /^Save$/ }).click();
			await expect(formAt(fileSection, 7)).toHaveCount(1);
			await expect(formAt(fileSection, 7).locator("textarea")).toHaveValue("gamma");
			await expect(commentRowAt(fileSection, 7)).toContainText("beta");
			await expect(commentRowAt(fileSection, 7)).not.toContainText("alpha");

			// The unsaved-form gate holds until the last form closes.
			await expect(approve).toBeDisabled();
			await formAt(fileSection, 7).getByRole("button", { name: /^Cancel$/ }).click();
			await expect(page.locator(".comment-form")).toHaveCount(0);
			await expect(approve).toBeEnabled();
		} finally {
			await meerkat.kill();
		}
	});

	test("open forms and posted comments, including on expanded context lines, survive every view toggle and a reload", async ({
		page,
	}) => {
		const lines = Array.from({ length: 40 }, (_, i) => `line ${i + 1}`);
		const fixture = makeFixture({
			files: {
				"src/lib.rs": "fn a() {}\nfn b() {}\nfn c() {}\n",
				"src/long.txt": `${lines.join("\n")}\n`,
			},
		});
		fixture.git("commit", "-q", "-m", "base");
		writeFileSync(join(fixture.dir, "src/lib.rs"), "fn a() {}\nfn b2() {}\nfn c() {}\nfn d() {}\n");
		lines[29] = "line 30 changed";
		writeFileSync(join(fixture.dir, "src/long.txt"), `${lines.join("\n")}\n`);
		fixture.git("add", "src/lib.rs", "src/long.txt");

		const meerkat = await startMeerkat({ fixture });
		try {
			await page.goto(meerkat.url);
			const lib = page.locator(".file-section").filter({ hasText: "src/lib.rs" });
			const long = page.locator(".file-section").filter({ hasText: "src/long.txt" });

			// A modified file renders split. One posted comment, one form with
			// a non-default finding type and learn flag, and a plain draft.
			await splitNewLine(lib, 2).click();
			await formAt(lib, 2).locator("textarea").fill("posted on two");
			await formAt(lib, 2).getByRole("button", { name: /^Add Comment$/ }).click();
			await expect(commentRowAt(lib, 2)).toContainText("posted on two");

			await splitNewLine(lib, 1).click();
			const kept = formAt(lib, 1);
			await kept.getByRole("button", { name: "Question", exact: true }).click();
			await kept.getByRole("checkbox", { name: /learn from this/ }).check();
			await kept.locator("textarea").fill("kept question");

			await splitNewLine(lib, 4).click();
			await expect(formAt(lib, 4)).toBeVisible();
			await formAt(lib, 4).locator("textarea").fill("second draft");

			// In unified mode, expand the context above the change until line 5
			// shows, then open a form on line 5 and post a comment on line 6.
			await page.getByRole("button", { name: "Unified", exact: true }).click();
			await expect(newLine(long, 5)).toHaveCount(0);
			while ((await newLine(long, 5).count()) === 0 || (await newLine(long, 6).count()) === 0) {
				await long.locator("td.diff-line-hunk-action button").first().click();
			}
			await newLine(long, 6).click();
			await formAt(long, 6).locator("textarea").fill("posted on context");
			await formAt(long, 6).getByRole("button", { name: /^Add Comment$/ }).click();
			await expect(commentRowAt(long, 6)).toContainText("posted on context");
			await newLine(long, 5).click();
			await formAt(long, 5).locator("textarea").fill("on a context line");

			const expectKept = async () => {
				await expect(kept).toHaveCount(1);
				await expect(kept.locator(".finding-chip.active")).toHaveText("Question");
				await expect(kept.getByRole("checkbox", { name: /learn from this/ })).toBeChecked();
				await expect(kept.locator("textarea")).toHaveValue("kept question");
				await expect(formAt(lib, 4).locator("textarea")).toHaveValue("second draft");
				await expect(commentRowAt(lib, 2)).toContainText("posted on two");
				await expect(formAt(long, 5).locator("textarea")).toHaveValue("on a context line");
				await expect(commentRowAt(long, 6)).toContainText("posted on context");
			};
			await expectKept();

			const wrap = page.getByRole("checkbox", { name: "Wrap" });
			for (const toggle of [
				() => wrap.click(),
				() => page.getByRole("button", { name: "Split", exact: true }).click(),
				() => wrap.click(),
				() => page.getByRole("button", { name: "Unified", exact: true }).click(),
			]) {
				await toggle();
				await expectKept();
			}

			await kept.getByRole("button", { name: /^Add Comment$/ }).click();
			await expect(commentRowAt(lib, 1)).toContainText("question L1 (new)");
			await expect(commentRowAt(lib, 1).getByRole("checkbox")).toBeChecked();
			await expect(commentRowAt(lib, 1)).toContainText("kept question");

			// A reload restores each open form's text and every posted comment.
			await page.reload();
			await expect(formAt(lib, 4).locator("textarea")).toHaveValue("second draft");
			await expect(formAt(long, 5).locator("textarea")).toHaveValue("on a context line");
			await expect(commentRowAt(long, 6)).toContainText("posted on context");
			await expect(commentRowAt(lib, 1)).toContainText("kept question");
		} finally {
			await meerkat.kill();
		}
	});

	test("a footer link scrolls to and focuses a form hidden by approving its file or by the filter", async ({
		page,
	}) => {
		const fixture = makeFixture({
			files: {
				"a_first.rs": "fn a() {}\nfn a2() {}\n",
				"b_second.rs": "fn b() {}\nfn b2() {}\n",
				"c_third.rs": "fn c() {}\nfn c2() {}\n",
			},
		});
		const meerkat = await startMeerkat({ fixture });
		try {
			await page.goto(meerkat.url);
			const section = (name: string) => page.locator(".file-section").filter({ hasText: name });
			const first = section("a_first.rs");
			const footer = page.locator(".decision-footer");
			const link = footer.getByRole("button", { name: "a_first.rs L2" });
			const form = formAt(first, 2);

			await newLine(first, 2).click();
			await form.locator("textarea").fill("hidden");
			await page.getByRole("button", { name: /^\+ Add global comment$/ }).click();

			await first.getByRole("checkbox", { name: "Approved" }).click();
			await expect(form).toHaveCount(0);
			await expect(footer).toContainText("2 unsaved forms open:");
			await expect(footer.getByRole("button", { name: "Global" })).toBeVisible();
			await link.click();
			await expect(form).toBeInViewport();
			await expect(form.locator("textarea")).toHaveValue("hidden");
			await expect(form.locator("textarea")).toBeFocused();

			// Hiding the first two files moves the third to the top of the list.
			await page.getByRole("button", { name: /^Toggle file list$/ }).click();
			await page.locator(".file-filter .filter-input").fill("third");
			await expect(first).toHaveCount(0);
			await expect(section("b_second.rs")).toHaveCount(0);
			await link.click();
			await expect(form).toBeInViewport();
			await expect(form.locator("textarea")).toHaveValue("hidden");
			// Every file shown again renders its diff, not a blank section.
			for (const name of ["a_first.rs", "b_second.rs", "c_third.rs"]) {
				await expect(newLine(section(name), 1)).toBeAttached();
			}

			await form.getByRole("button", { name: /^Cancel$/ }).click();
			await page.locator(".global-comments").getByRole("button", { name: /^Cancel$/ }).click();
			await expect(footer.locator(".dirty-marker")).toHaveCount(0);
			await expect(page.getByRole("button", { name: /^Approve$/ })).toBeEnabled();
		} finally {
			await meerkat.kill();
		}
	});
});

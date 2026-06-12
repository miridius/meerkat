import { type Page } from "@playwright/test";
import { expect, test } from "./lib/test";
import { startMeerkat } from "./lib/runner";

// Each test in this file goes through the same lifecycle: start
// meerkat → drive UI → cancel out (exit 1) so meerkat tears down.
async function teardown(meerkat: { kill: () => Promise<void> }) {
	await meerkat.kill();
}

async function addGlobalComment(page: Page, body: string, kind = "Issue") {
	// Empty-state shows "+ Add global comment"; populated section
	// shows "+ Add another". Exact match on either — do NOT
	// fuzzy-match anything containing "Add", which would also
	// catch the form's submit button.
	const trigger = page
		.getByRole("button", { name: "+ Add global comment" })
		.or(page.getByRole("button", { name: "+ Add another" }));
	await trigger.first().click();
	const form = page.locator(".comment-form");
	await form.locator("textarea").fill(body);
	await form.getByRole("button", { name: new RegExp(`^${kind}$`) }).click();
	await form.getByRole("button", { name: /^Add Global Comment$/ }).click();
	await expect(form).toBeHidden();
}

test.describe("global comments — add / edit / remove", () => {
	test("add a global comment, edit its body, remove it", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			await addGlobalComment(page, "first version", "Issue");

			// Global comments live in `<section class="global-comments">`
			// with each entry rendered as a `.note.note-{findingType}` card.
			const card = page.locator(".global-comments .note").first();
			await expect(card).toContainText("first version");

			await card.getByRole("button", { name: /^Edit$/ }).click();
			const editForm = page.locator(".comment-form");
			await editForm.locator("textarea").fill("second version");
			// Edit forms use submitLabel="Save".
			await editForm.getByRole("button", { name: /^Save$/ }).click();
			await expect(editForm).toBeHidden();
			await expect(card).toContainText("second version");
			await expect(card).not.toContainText("first version");

			await card.getByRole("button", { name: /^Remove$/ }).click();
			await expect(page.locator(".global-comments .note")).toHaveCount(0);
		} finally {
			await teardown(meerkat);
		}
	});

	test("each finding type renders a distinct badge", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			for (const kind of ["Issue", "Follow-up", "Question", "Suggestion"]) {
				await addGlobalComment(page, `body for ${kind}`, kind);
			}

			const list = page.locator(".global-comments");
			await expect(list).toContainText("body for Issue");
			await expect(list).toContainText("body for Follow-up");
			await expect(list).toContainText("body for Question");
			await expect(list).toContainText("body for Suggestion");
		} finally {
			await teardown(meerkat);
		}
	});
});

test.describe("file comments", () => {
	test("add a file comment via the per-file button, edit, remove", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			const fileSection = page.locator(".file-section").filter({ hasText: "src/main.rs" });
			await fileSection.getByRole("button", { name: /^\+ Add file comment$/ }).click();

			const form = page.locator(".comment-form");
			await form.locator("textarea").fill("file-level concern");
			await form.getByRole("button", { name: /^Question$/ }).click();
			await form.getByRole("button", { name: /^Add File Comment$/ }).click();
			await expect(form).toBeHidden();

			// File comments are rendered as `.note.file-note` inside
			// the file's `.file-section` wrapper.
			const card = fileSection.locator(".note.file-note").first();
			await expect(card).toContainText("file-level concern");

			await card.getByRole("button", { name: /^Edit$/ }).click();
			const editForm = page.locator(".comment-form");
			await editForm.locator("textarea").fill("file-level concern v2");
			await editForm.getByRole("button", { name: /^Save$/ }).click();
			await expect(card).toContainText("file-level concern v2");

			await card.getByRole("button", { name: /^Remove$/ }).click();
			await expect(fileSection.locator(".note.file-note")).toHaveCount(0);
		} finally {
			await teardown(meerkat);
		}
	});

	// The language-rust class on the rendered fence is the observable
	// end of the fileName → languageFor → fence-tag chain.
	test("file-comment suggestion fence carries the file's language", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			const fileSection = page.locator(".file-section").filter({ hasText: "src/main.rs" });
			await fileSection.getByRole("button", { name: /^\+ Add file comment$/ }).click();

			const form = page.locator(".comment-form");
			await form.getByRole("button", { name: /^Suggestion$/ }).click();
			await form.locator("textarea.prose").fill("suggested rewrite");
			const editor = form.locator(".code-host .cm-content");
			await editor.click();
			await page.keyboard.type("fn renamed() {}");
			await form.getByRole("button", { name: /^Add File Comment$/ }).click();
			await expect(form).toBeHidden();

			const card = fileSection.locator(".note.file-note").first();
			await expect(card).toContainText("suggested rewrite");
			await expect(card.locator("pre code.rust")).toContainText("fn renamed() {}");
		} finally {
			await teardown(meerkat);
		}
	});
});

test.describe("commit-message comments", () => {
	test("clicking the L1 gutter row opens a commit-msg form, comment lands in the gutter", async ({
		page,
	}) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			await page.getByRole("button", { name: "Comment on commit message line 1" }).click();

			const form = page.locator(".comment-form");
			await expect(form).toBeVisible();
			await form.locator("textarea").fill("subject too vague");
			await form.getByRole("button", { name: /^Issue$/ }).click();
			// Commit-msg forms reuse a label like "Add Commit Message Comment"
			// or similar. Use a permissive matcher so this test doesn't
			// re-break if the label wording shifts.
			await form
				.getByRole("button", {
					name: /Add (Commit[- ]?Msg|Commit[- ]?Message|Comment)/i,
				})
				.click();
			await expect(form).toBeHidden();

			// The new comment is visible somewhere on the page (the
			// commit-message section above the diff).
			await expect(page.locator(".note").filter({ hasText: "subject too vague" })).toBeVisible();
		} finally {
			await teardown(meerkat);
		}
	});

	test("dragging across two gutter blocks opens one multi-block form", async ({ page }) => {
		// Dragging across multiple commit-message blocks should open a
		// single form anchored at `min(start)..max(end)` — not one form
		// per block, and the start block's `phx-click` must not also
		// fire after pointerup synthesizes its trailing click.
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			const block1 = page.locator("#commit-msg-gutter li").nth(0);
			const block2 = page.locator("#commit-msg-gutter li").nth(1);

			const box1 = await block1.boundingBox();
			const box2 = await block2.boundingBox();
			if (!box1 || !box2) throw new Error("commit-msg blocks not found");

			// Real mouse drag from block 1 to block 2.
			await page.mouse.move(box1.x + 10, box1.y + box1.height / 2);
			await page.mouse.down();
			await page.mouse.move(box2.x + 10, box2.y + box2.height / 2, { steps: 5 });
			await page.mouse.up();

			// One form visible at the multi-block anchor (L1..L4 covers
			// the subject + the body block in the default fixture).
			const form = page.locator(".comment-form");
			await expect(form).toBeVisible();
			await expect(page.locator(".comment-form")).toHaveCount(1);

			await form.locator("textarea").fill("subject + body together");
			await form
				.getByRole("button", {
					name: /Add (Commit[- ]?Msg|Commit[- ]?Message|Comment)/i,
				})
				.click();
			await expect(form).toBeHidden();

			await expect(
				page.locator(".note").filter({ hasText: "subject + body together" }),
			).toBeVisible();
		} finally {
			await teardown(meerkat);
		}
	});
});

test.describe("form-cancel regression", () => {
	test("opening then cancelling a file-comment form preserves other comments", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			// Baseline: a global comment and a file comment.
			await addGlobalComment(page, "global baseline", "Issue");

			const fileSection = page.locator(".file-section").filter({ hasText: "src/main.rs" });
			await fileSection.getByRole("button", { name: /^\+ Add file comment$/ }).click();
			const baselineForm = page.locator(".comment-form");
			await baselineForm.locator("textarea").fill("file baseline");
			await baselineForm.getByRole("button", { name: /^Issue$/ }).click();
			await baselineForm.getByRole("button", { name: /^Add File Comment$/ }).click();
			await expect(baselineForm).toBeHidden();

			// Open + cancel a NEW file form three times.
			for (let i = 0; i < 3; i++) {
				await fileSection.getByRole("button", { name: /^\+ Add file comment$/ }).click();
				const form = page.locator(".comment-form");
				await form.locator("textarea").fill(`draft ${i}`);
				// Cancel inside the form — there is also a page-level
				// Cancel; scoping to .comment-form picks the right one.
				await form.getByRole("button", { name: /^Cancel$/ }).click();
				await expect(form).toBeHidden();
			}

			// The original bug: cancel would refresh the page and lose
			// other comments. With state-on-server, only the form's UI
			// flag flips.
			await expect(page.locator(".global-comments .note")).toContainText("global baseline");
			await expect(fileSection.locator(".note.file-note")).toContainText("file baseline");
		} finally {
			await teardown(meerkat);
		}
	});
});

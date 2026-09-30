import { expect, test } from "./lib/test";
import { makeFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";

// The browser seams of commenting: the commit-message gutter's pointer
// hook, and the Suggestion composer's CodeMirror editor. Adding, editing,
// removing and cancelling comments on every surface is covered by the
// LiveView tests.

test.describe("commit-message comments", () => {
	test("a click on a gutter row opens its form, and a drag across two blocks opens one form for both", async ({
		page,
	}) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			const form = page.locator(".comment-form");
			await page.getByRole("button", { name: "Comment on commit message line 1" }).click();
			await expect(form, "a click on L1 opens the commit-message form").toBeVisible();
			await form.getByRole("button", { name: /^Cancel$/ }).click();
			await expect(form).toBeHidden();

			// Dragging across multiple commit-message blocks should open a
			// single form anchored at `min(start)..max(end)`: not one form
			// per block, and the start block's `phx-click` must not also
			// fire after pointerup synthesizes its trailing click.
			const block1 = page.locator("#commit-msg-gutter li").nth(0);
			const block2 = page.locator("#commit-msg-gutter li").nth(1);
			const box1 = await block1.boundingBox();
			const box2 = await block2.boundingBox();
			if (!box1 || !box2) throw new Error("commit-msg blocks not found");

			await page.mouse.move(box1.x + 10, box1.y + box1.height / 2);
			await page.mouse.down();
			await page.mouse.move(box2.x + 10, box2.y + box2.height / 2, { steps: 5 });
			await page.mouse.up();

			await expect(form).toBeVisible();
			await expect(form, "the drag opens exactly one form").toHaveCount(1);

			await form.locator("textarea").fill("subject + body together");
			await form.getByRole("button", { name: /^Issue$/ }).click();
			await form.getByRole("button", { name: /^Add Commit Message Comment$/ }).click();
			await expect(form).toBeHidden();

			const note = page.locator(".commit-msg-note").filter({ hasText: "subject + body together" });
			await expect(
				note.locator(".line-anchor"),
				"the comment spans the subject and the body block (L1..L4 in the default fixture)",
			).toHaveText("L1–4");
		} finally {
			await meerkat.kill();
		}
	});

	test("dragging across four gutter blocks, either way, spans all of them", async ({ page }) => {
		const fixture = makeFixture({ commitMsg: "Subject\n\nBody paragraph.\n\n- one\n- two\n" });
		const meerkat = await startMeerkat({ fixture });
		try {
			await page.goto(meerkat.url);
			const blocks = page.locator("#commit-msg-gutter > li");
			await expect(blocks).toHaveCount(4);
			const last = (await blocks.count()) - 1;
			const startOf = (i: number) => blocks.nth(i).getAttribute("data-start-line");
			const endOf = (i: number) => blocks.nth(i).getAttribute("data-end-line");

			const drag = async (from: number, to: number) => {
				const a = await blocks.nth(from).boundingBox();
				const b = await blocks.nth(to).boundingBox();
				if (!a || !b) throw new Error("commit-msg blocks not found");
				await page.mouse.move(a.x + 10, a.y + a.height / 2);
				await page.mouse.down();
				await page.mouse.move(b.x + 10, b.y + b.height / 2, { steps: 10 });
				await page.mouse.up();
			};
			const labels = page.locator(".commit-msg-form .line-anchor");

			await drag(0, last);
			await expect(labels).toHaveText([`L${await startOf(0)}–${await endOf(last)}`]);
			await page.locator(".commit-msg-form").getByRole("button", { name: /^Cancel$/ }).click();
			await expect(labels).toHaveCount(0);

			await drag(last, 1);
			await expect(labels).toHaveText([`L${await startOf(1)}–${await endOf(last)}`]);
		} finally {
			await meerkat.kill();
		}
	});

	test("hovering a gutter number fills it with the accent colour", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);
			const num = page.locator("#commit-msg-gutter .gutter-line-num").first();

			await num.hover();
			await expect(num).toHaveCSS("background-color", "rgb(31, 111, 235)");
		} finally {
			await meerkat.kill();
		}
	});

	test("only the blocks in a gutter drag's range are shaded while dragging", async ({ page }) => {
		const fixture = makeFixture({ commitMsg: "Subject\n\nBody paragraph.\n\n- one\n- two\n" });
		const meerkat = await startMeerkat({ fixture });
		try {
			await page.goto(meerkat.url);
			const blocks = page.locator("#commit-msg-gutter > li");
			await expect(blocks).toHaveCount(4);
			const a = await blocks.nth(0).boundingBox();
			const b = await blocks.nth(1).boundingBox();
			if (!a || !b) throw new Error("commit-msg blocks not found");

			await page.mouse.move(a.x + 10, a.y + a.height / 2);
			await page.mouse.down();
			await page.mouse.move(b.x + 10, b.y + b.height / 2, { steps: 5 });

			await expect(blocks.nth(0)).toHaveClass(/dragging/);
			await expect(blocks.nth(0)).toHaveCSS("background-color", "rgba(31, 111, 235, 0.32)");
			await expect(blocks.nth(1)).toHaveCSS("background-color", "rgba(31, 111, 235, 0.32)");
			await expect(blocks.nth(2)).not.toHaveClass(/dragging/);
			await expect(blocks.nth(2)).not.toHaveCSS("background-color", "rgba(31, 111, 235, 0.32)");
			await page.mouse.up();
		} finally {
			await meerkat.kill();
		}
	});
});

test.describe("suggestion comments", () => {
	// The language-rust class on the rendered fence is the observable
	// end of the fileName → languageFor → fence-tag chain.
	test("Suggestion swaps the textarea for a CodeMirror editor whose contents land in a fence tagged with the file's language", async ({
		page,
	}) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			const fileSection = page.locator(".file-section").filter({ hasText: "src/main.rs" });
			await fileSection.getByRole("button", { name: /^\+ Add file comment$/ }).click();

			const form = page.locator(".comment-form");
			await expect(form.locator("textarea"), "plain mode renders a single textarea").toHaveCount(1);
			await form.getByRole("button", { name: /^Suggestion$/ }).click();
			await expect(form.locator(".code-host .cm-editor")).toBeVisible();
			await expect(form.locator("textarea.prose"), "the prose textarea sits above the editor").toBeVisible();

			await form.locator("textarea.prose").fill("suggested rewrite");
			await form.locator(".code-host .cm-content").click();
			await page.keyboard.type("fn renamed() {}");
			await form.getByRole("button", { name: /^Add File Comment$/ }).click();
			await expect(form).toBeHidden();

			// Without the fence GitHub doesn't render a suggestion block.
			const card = fileSection.locator(".note.file-note").first();
			await expect(card).toContainText("suggested rewrite");
			const code = card.locator("pre code.language-rust");
			await expect(code).toContainText("fn renamed() {}");
			await expect(code, "the prose stays outside the fence").not.toContainText("suggested rewrite");
		} finally {
			await meerkat.kill();
		}
	});
});

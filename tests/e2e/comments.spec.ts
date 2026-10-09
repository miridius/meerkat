import { expect, test } from "./lib/test";
import { makeFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";

// The browser seam of commit-message comments: the gutter's pointer hook.
// Adding, editing, removing and cancelling comments on every surface is
// covered by the LiveView tests; the Suggestion composer's CodeMirror
// editor by decision.spec.ts.
test.describe("commit-message comments", () => {
	test("a gutter row highlights on hover and opens its form on a click, and a drag either way shades and spans every block it crosses in one form", async ({
		page,
	}) => {
		const fixture = makeFixture({ commitMsg: "Subject\n\nBody paragraph.\n\n- one\n- two\n" });
		const meerkat = await startMeerkat({ fixture });
		try {
			await page.goto(meerkat.url);
			const blocks = page.locator("#commit-msg-gutter > li");
			await expect(blocks).toHaveCount(4);
			const last = (await blocks.count()) - 1;
			const startOf = (i: number) => blocks.nth(i).getAttribute("data-start-line");
			const endOf = (i: number) => blocks.nth(i).getAttribute("data-end-line");
			const centre = async (i: number) => {
				const box = await blocks.nth(i).boundingBox();
				if (!box) throw new Error("commit-msg block not found");
				return { x: box.x + 10, y: box.y + box.height / 2 };
			};
			const form = page.locator(".comment-form");
			const labels = page.locator(".commit-msg-form .line-anchor");

			const num = page.locator("#commit-msg-gutter .gutter-line-num").first();
			await num.hover();
			await expect(num, "hovering a gutter number fills it with the accent colour").toHaveCSS(
				"background-color",
				"rgb(31, 111, 235)",
			);

			await page.getByRole("button", { name: "Comment on commit message line 1" }).click();
			await expect(form, "a click on L1 opens the commit-message form").toBeVisible();
			await form.getByRole("button", { name: /^Cancel$/ }).click();
			await expect(form).toBeHidden();

			// Only the blocks in a drag's range are shaded while dragging.
			const from = await centre(0);
			await page.mouse.move(from.x, from.y);
			await page.mouse.down();
			const second = await centre(1);
			await page.mouse.move(second.x, second.y, { steps: 5 });
			const shade = "rgba(31, 111, 235, 0.32)";
			await expect(blocks.nth(0)).toHaveClass(/dragging/);
			await expect(blocks.nth(0)).toHaveCSS("background-color", shade);
			await expect(blocks.nth(1)).toHaveCSS("background-color", shade);
			await expect(blocks.nth(2)).not.toHaveClass(/dragging/);
			await expect(blocks.nth(2)).not.toHaveCSS("background-color", shade);

			// Releasing over the last block opens a single form anchored at
			// `min(start)..max(end)`: not one form per block, and the start
			// block's `phx-click` must not also fire after pointerup
			// synthesizes its trailing click.
			const end = await centre(last);
			await page.mouse.move(end.x, end.y, { steps: 5 });
			await page.mouse.up();
			await expect(form, "the drag opens exactly one form").toHaveCount(1);
			const span = `L${await startOf(0)}–${await endOf(last)}`;
			await expect(labels).toHaveText([span]);

			await form.locator("textarea").fill("subject + body together");
			await form.getByRole("button", { name: /^Issue$/ }).click();
			await form.getByRole("button", { name: /^Add Commit Message Comment$/ }).click();
			await expect(form).toBeHidden();
			const note = page.locator(".commit-msg-note").filter({ hasText: "subject + body together" });
			await expect(note.locator(".line-anchor"), "the comment spans every block dragged over").toHaveText(
				span,
			);

			// Dragging upwards spans the same way.
			const up = await centre(last);
			await page.mouse.move(up.x, up.y);
			await page.mouse.down();
			const target = await centre(1);
			await page.mouse.move(target.x, target.y, { steps: 10 });
			await page.mouse.up();
			await expect(labels).toHaveText([`L${await startOf(1)}–${await endOf(last)}`]);
		} finally {
			await meerkat.kill();
		}
	});
});

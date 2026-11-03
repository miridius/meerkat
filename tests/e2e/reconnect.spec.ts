// LiveView drops every event pushed while its channel is down, so the
// page must take no input from the moment the connection drops until it
// rejoins, while its text stays selectable. LiveViewTest has no browser
// to drop a connection under, and the gate lives in the page's script.
import type { Page } from "@playwright/test";
import { startMeerkat } from "./lib/runner";
import { expect, test } from "./lib/test";
import { liveTransports } from "./lib/transports";

// Lets the LiveView connect, then drops its connection on `drop()` and
// refuses both transports until `restore()`.
async function droppableConnection(page: Page) {
	const transports = await liveTransports(page);
	const root = page.locator("[data-phx-main]");
	return {
		drop: async () => {
			await transports.drop();
			await expect(root).toHaveClass(/phx-client-error/);
		},
		restore: async () => {
			transports.refuse(false);
			await expect(root).toHaveClass(/phx-connected/);
		},
	};
}

test("a dropped connection makes the page refuse input until it reconnects, and keeps its text selectable", async ({
	page,
}) => {
	const meerkat = await startMeerkat();
	try {
		const connection = await droppableConnection(page);
		await page.goto(meerkat.url);
		const file = page.locator(".file-section").first();
		const approved = file.getByRole("checkbox", { name: "Approved" });
		await page.getByRole("button", { name: /^\+ Add global comment$/ }).click();
		const textarea = page.locator(".global-comments .comment-form textarea").first();
		await textarea.click();
		await page.keyboard.type("abc");
		await page.keyboard.press("ArrowLeft");

		await connection.drop();
		await expect(page.locator(".conn-indicator")).toHaveText("disconnected", { useInnerText: true });
		await approved.click();
		await expect(approved, "the click does not tick a box the server never hears of").not.toBeChecked();
		await expect(textarea, "the click moves no focus").toBeFocused();
		await page.keyboard.type("lost");
		await page.keyboard.press("Tab");
		await expect(textarea).toHaveValue("abc");
		await expect(textarea).toBeFocused();
		// A press in the focused field still moves its caret.
		const field = await textarea.boundingBox();
		if (!field) throw new Error("textarea has no box");
		await page.mouse.click(field.x + 2, field.y + 10);

		const code = file.getByRole("cell", { name: "Lorem ipsum dolor sit amet." });
		const from = await code.boundingBox();
		if (!from) throw new Error("code cell has no box");
		await page.mouse.move(from.x + 2, from.y + from.height / 2);
		await page.mouse.down();
		await page.mouse.move(from.x + from.width - 2, from.y + from.height / 2, { steps: 5 });
		await page.mouse.up();
		expect(await page.evaluate(() => window.getSelection()?.toString() ?? ""), "diff text stays selectable").not.toBe("");
		// Selecting text left the field, as it does when connected.
		await textarea.focus();

		await connection.restore();
		await expect(textarea, "reconnecting moves no focus").toBeFocused();
		await page.keyboard.type("X");
		await expect(textarea, "the caret is where the press put it").toHaveValue("Xabc");

		await approved.click();
		await expect(approved).toBeChecked();
		await page.reload();
		await expect(approved, "the server recorded the click made after reconnecting").toBeChecked();
	} finally {
		await meerkat.kill();
	}
});

test("a line drag released while disconnected ends without a comment form, and a suggestion takes no paste", async ({
	page,
}) => {
	const meerkat = await startMeerkat();
	try {
		const connection = await droppableConnection(page);
		await page.goto(meerkat.url);
		const forms = page.locator(".comment-form");

		// The diff's gutter.
		const file = page.locator(".file-section").first();
		const code = file.getByRole("cell", { name: "Lorem ipsum dolor sit amet." });
		const lineNums = file.locator("td.diff-line-num span[data-line-new-num]");
		await lineNums.first().hover();
		await page.mouse.down();
		await expect(file.locator(".drag-selecting").first()).toBeVisible();
		await connection.drop();
		await page.mouse.up();
		await code.hover();
		await expect(file.locator(".drag-selecting"), "the release ends the drag").toHaveCount(0);
		await connection.restore();
		await code.click();
		// Replies come in order, so once the form the last line asks for is
		// shown, so is any form the click on code asked for.
		const last = lineNums.last();
		const n = await last.getAttribute("data-line-new-num");
		await last.click();
		const form = file.locator(`tr.meerkat-form-row[data-meerkat-form-anchor="${n}"] .comment-form`);
		await expect(form).toBeVisible();
		await expect(forms).toHaveCount(1);

		// CodeMirror handles a paste itself, not as `beforeinput`.
		await form.getByRole("button", { name: /^Suggestion$/ }).click();
		const editor = form.locator(".code-host .cm-content");
		await editor.click();
		const before = await editor.textContent();
		await connection.drop();
		await editor.evaluate((el) => {
			const clipboardData = new DataTransfer();
			clipboardData.setData("text/plain", "pasted");
			el.dispatchEvent(new ClipboardEvent("paste", { clipboardData, bubbles: true, cancelable: true }));
		});
		expect(await editor.textContent(), "a suggestion takes no paste").toBe(before);
		await connection.restore();
		await forms.getByRole("button", { name: /^Cancel$/ }).click();
		await expect(forms).toHaveCount(0);

		// The commit message's gutter.
		const blocks = page.locator("#commit-msg-gutter > li");
		await blocks.first().scrollIntoViewIfNeeded();
		const centre = async (i: number) => {
			const box = await blocks.nth(i).boundingBox();
			if (!box) throw new Error("commit-msg block not found");
			return { x: box.x + 10, y: box.y + box.height / 2 };
		};
		const from = await centre(0);
		await page.mouse.move(from.x, from.y);
		await page.mouse.down();
		const to = await centre(1);
		await page.mouse.move(to.x, to.y, { steps: 5 });
		await expect(blocks.nth(0)).toHaveClass(/dragging/);
		await connection.drop();
		await page.mouse.up();
		const off = await centre(2);
		await page.mouse.move(off.x, off.y, { steps: 5 });
		await expect(page.locator("#commit-msg-gutter .dragging"), "the release ends the drag").toHaveCount(0);
		await connection.restore();
		await page.getByRole("button", { name: "Comment on commit message line 1" }).click();
		await expect(page.locator(".commit-msg-form .line-anchor"), "the click asks for its own line").toHaveText(["L1–1"]);
	} finally {
		await meerkat.kill();
	}
});

test("the Send Feedback shortcut does nothing while the page is disconnected", async ({ page }) => {
	const meerkat = await startMeerkat();
	try {
		const connection = await droppableConnection(page);
		await page.goto(meerkat.url);
		await page.getByRole("button", { name: /^\+ Add global comment$/ }).click();
		const form = page.locator(".global-comments .comment-form");
		await form.locator("textarea").first().fill("needs work");
		await form.locator(".btn-submit").click();
		await expect(form).toHaveCount(0);
		const sendFeedback = page.locator("#send-feedback-btn");
		await expect(sendFeedback).toBeEnabled();
		// LiveView would drop the push of a click made while disconnected,
		// so count the clicks the button gets.
		await sendFeedback.evaluate((button) => {
			button.dataset.clicks = "0";
			button.addEventListener("click", () => {
				button.dataset.clicks = String(Number(button.dataset.clicks) + 1);
			});
		});

		// Desktop Chrome emulation sends a Windows user agent, so the page
		// takes Ctrl, not Cmd, even on a macOS runner.
		await connection.drop();
		await page.keyboard.press("Control+Shift+Enter");
		await expect(sendFeedback).toHaveAttribute("data-clicks", "0");

		await connection.restore();
		await page.keyboard.press("Control+Shift+Enter");
		await expect(page.locator("main.review.done")).toHaveCount(1);
	} finally {
		await meerkat.kill();
	}
});

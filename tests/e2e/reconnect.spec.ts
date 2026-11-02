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
		// A real mouse click: Playwright's own `click` waits until the
		// element can take the click.
		const box = await approved.boundingBox();
		if (!box) throw new Error("Approved has no box");
		await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
		await expect(approved, "the click does not tick a box the server never hears of").not.toBeChecked();
		await expect(textarea, "the click moves no focus").toBeFocused();
		await page.keyboard.type("lost");
		await page.keyboard.press("Tab");
		await expect(textarea).toHaveValue("abc");
		await expect(textarea).toBeFocused();

		const code = file.getByRole("cell", { name: "Lorem ipsum dolor sit amet." });
		const from = await code.boundingBox();
		if (!from) throw new Error("code cell has no box");
		await page.mouse.move(from.x + 2, from.y + from.height / 2);
		await page.mouse.down();
		await page.mouse.move(from.x + from.width - 2, from.y + from.height / 2, { steps: 5 });
		await page.mouse.up();
		expect(await page.evaluate(() => window.getSelection()?.toString() ?? ""), "diff text stays selectable").not.toBe("");

		await connection.restore();
		await textarea.focus();
		await page.keyboard.type("X");
		await expect(textarea, "the caret is where it was").toHaveValue("abXc");

		await approved.click();
		await expect(approved).toBeChecked();
		await page.reload();
		await expect(approved, "the server recorded the click made after reconnecting").toBeChecked();
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

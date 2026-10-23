// LiveView drops every event pushed while its channel is down, so the
// page must take no input from the moment the connection drops until it
// rejoins. LiveViewTest has no browser to drop a connection under, and
// the gate lives in a client hook.
import type { Page } from "@playwright/test";
import { startMeerkat } from "./lib/runner";
import { expect, test } from "./lib/test";

// Lets the LiveView connect, then drops its connection on `drop()` and
// refuses both transports until `restore()`.
async function droppableConnection(page: Page) {
	let refuse = false;
	let current: { close: () => Promise<void> } | null = null;
	await page.routeWebSocket(/\/live\/websocket/, (ws) => {
		if (refuse) return ws.close();
		ws.connectToServer();
		current = ws;
	});
	await page.route(/\/live\/longpoll/, (route) => (refuse ? route.abort() : route.continue()));
	const root = page.locator("[data-phx-main]");
	return {
		drop: async () => {
			refuse = true;
			await current?.close();
			await expect(root).toHaveClass(/phx-client-error/);
		},
		restore: async () => {
			refuse = false;
			await expect(root).toHaveClass(/phx-connected/);
		},
	};
}

async function addGlobalComment(page: Page) {
	await page.getByRole("button", { name: /^\+ Add global comment$/ }).click();
	const form = page.locator(".global-comments .comment-form");
	await form.locator("textarea").first().fill("needs work");
	await form.locator(".btn-submit").click();
	await expect(form).toHaveCount(0);
}

test("a dropped connection makes the page refuse input until it reconnects, then gives focus back", async ({
	page,
}) => {
	const meerkat = await startMeerkat();
	try {
		const connection = await droppableConnection(page);
		await page.goto(meerkat.url);
		const main = page.locator("main#meerkat-root");
		const approved = page.locator(".file-section").first().getByRole("checkbox", { name: "Approved" });
		await page.getByRole("button", { name: /^\+ Add global comment$/ }).click();
		const textarea = page.locator(".global-comments .comment-form textarea").first();
		await textarea.click();
		await page.keyboard.type("abc");
		await page.keyboard.press("ArrowLeft");

		await connection.drop();
		await expect(main).toHaveAttribute("inert");
		await expect(page.locator(".conn-indicator")).toHaveText("disconnected", { useInnerText: true });
		// A real mouse click: Playwright's own `click` waits until the
		// element can take the click.
		const box = await approved.boundingBox();
		if (!box) throw new Error("Approved has no box");
		await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
		await page.keyboard.type("lost");
		await expect(approved, "the click does not tick a box the server never hears of").not.toBeChecked();
		await expect(textarea).toHaveValue("abc");

		await connection.restore();
		await expect(main).not.toHaveAttribute("inert");
		await expect(textarea).toBeFocused();
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
		await addGlobalComment(page);
		const sendFeedback = page.locator("#send-feedback-btn");
		await expect(sendFeedback).toBeEnabled();
		const mac = (await page.locator("#send-feedback-hint").textContent()) === "⇧⌘↩";
		const shortcut = mac ? "Meta+Shift+Enter" : "Control+Shift+Enter";
		// LiveView would drop the push of a click made while disconnected,
		// so count the clicks the button gets.
		await sendFeedback.evaluate((button) => {
			button.dataset.clicks = "0";
			button.addEventListener("click", () => {
				button.dataset.clicks = String(Number(button.dataset.clicks) + 1);
			});
		});

		await connection.drop();
		await page.keyboard.press(shortcut);
		await expect(sendFeedback).toHaveAttribute("data-clicks", "0");

		await connection.restore();
		await page.keyboard.press(shortcut);
		await expect(page.locator("main.review.done")).toHaveCount(1);
	} finally {
		await meerkat.kill();
	}
});

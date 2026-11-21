// LiveView drops every event pushed while its channel is down, so the page
// must take no input from its first paint until LiveView joins, and from the
// moment the connection drops until it rejoins, while its text stays
// selectable. LiveViewTest has no browser to drop a connection under, and
// the gate lives in the page's script; which events it cancels or stops is
// covered by assets/ts/connectionGate.test.ts. This spec uses
// `unjoinedTest`: `test` waits for the join on every `goto`.
import type { Locator, Page } from "@playwright/test";
import { startMeerkat } from "./lib/runner";
import { expect, unjoinedTest as test } from "./lib/test";
import { liveTransports } from "./lib/transports";

// Real mouse clicks at each control's centre: Playwright's own `click`
// waits until the element can take the click.
async function clickThrough(page: Page, controls: Locator[]) {
	for (const control of controls) {
		const box = await control.boundingBox();
		if (!box) throw new Error("control has no box");
		await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
	}
}

test("the page takes no input until LiveView connects or while its connection is down, keeps its text selectable, and ends a drag released meanwhile", async ({
	page,
}) => {
	const meerkat = await startMeerkat();
	// Holding back the app bundle holds the page at its first paint.
	let release = () => {};
	const held = new Promise<void>((resolve) => {
		release = resolve;
	});
	try {
		// Refusing both LiveView transports makes the first connect fail.
		const transports = await liveTransports(page);
		transports.refuse(true);
		await page.route(/\/assets\/app-[^/]*\.js$/, async (route) => {
			await held;
			await route.continue();
		});
		await page.goto(meerkat.url, { waitUntil: "commit" });

		const root = page.locator("[data-phx-main]");
		const pill = page.locator(".conn-indicator");
		const file = page.locator(".file-section").first();
		const approved = file.getByRole("checkbox", { name: "Approved" });
		const addGlobal = page.getByRole("button", { name: /^\+ Add global comment$/ });
		const forms = page.locator(".comment-form");
		const drop = async () => {
			await transports.drop();
			await expect(root).toHaveClass(/phx-client-error/);
		};
		const restore = async () => {
			transports.refuse(false);
			await expect(root).toHaveClass(/phx-connected/);
		};

		await test.step("before LiveView first connects", async () => {
			await expect(pill).toHaveText("connecting…", { useInnerText: true });
			await clickThrough(page, [approved, addGlobal]);
			await expect(approved, "the click does not tick a box the server never hears of").not.toBeChecked();

			release();
			await expect(root).toHaveClass(/phx-client-error/);
			await expect(pill).toHaveText("disconnected", { useInnerText: true });
			await clickThrough(page, [approved, addGlobal]);
			await expect(approved, "a failed connect leaves the page refusing clicks").not.toBeChecked();

			await restore();
			await expect(pill).toHaveText("connected", { useInnerText: true });
			await expect(approved).not.toBeChecked();
			await expect(forms).toHaveCount(0);
		});

		const textarea = page.locator(".global-comments .comment-form textarea").first();
		await test.step("a dropped connection refuses clicks, typing and focus moves, and keeps text selectable", async () => {
			await addGlobal.click();
			await textarea.click();
			await page.keyboard.type("abc");
			await page.keyboard.press("ArrowLeft");

			await drop();
			await expect(pill).toHaveText("disconnected", { useInnerText: true });
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

			await restore();
			await expect(textarea, "reconnecting moves no focus").toBeFocused();
			await page.keyboard.type("X");
			await expect(textarea, "the caret is where the press put it").toHaveValue("Xabc");
			await page.locator(".global-comments .comment-form .btn-submit").click();
			await expect(forms).toHaveCount(0);

			await approved.click();
			await expect(approved).toBeChecked();
			await page.reload();
			await expect(root).toHaveClass(/phx-connected/);
			await expect(approved, "the server recorded the click made after reconnecting").toBeChecked();
			await approved.uncheck();
		});

		await test.step("a drag released while disconnected ends without a form, and a suggestion takes no paste", async () => {
			const lineNums = file.locator("td.diff-line-num span[data-line-new-num]");
			await lineNums.first().hover();
			await page.mouse.down();
			await expect(file.locator(".drag-selecting").first()).toBeVisible();
			await file.getByRole("cell", { name: "Lorem ipsum dolor sit amet." }).hover();
			await drop();
			await page.mouse.up();
			await expect(file.locator(".drag-selecting"), "the release ends the drag").toHaveCount(0);
			await restore();
			// A click on code with no move since the release.
			await page.mouse.down();
			await page.mouse.up();
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
			await drop();
			const paste = () =>
				editor.evaluate((el) => {
					const clipboardData = new DataTransfer();
					clipboardData.setData("text/plain", "pasted");
					el.dispatchEvent(new ClipboardEvent("paste", { clipboardData, bubbles: true, cancelable: true }));
				});
			await paste();
			expect(await editor.textContent(), "a suggestion takes no paste").toBe(before);
			await restore();
			await paste();
			await expect(editor, "the same paste lands once connected").toContainText("pasted");
			await forms.getByRole("button", { name: /^Cancel$/ }).click();
			await expect(forms).toHaveCount(0);
		});

		await test.step("the commit message's gutter ends a drag released while disconnected", async () => {
			const blocks = page.locator("#commit-msg-gutter > li");
			const dragging = page.locator("#commit-msg-gutter .dragging");
			await blocks.first().scrollIntoViewIfNeeded();
			const centre = async (i: number) => {
				const box = await blocks.nth(i).boundingBox();
				if (!box) throw new Error("commit-msg block not found");
				return { x: box.x + 10, y: box.y + box.height / 2 };
			};
			const from = await centre(0);
			const to = await centre(1);
			await page.mouse.move(from.x, from.y);
			await page.mouse.down();
			await page.mouse.move(to.x, to.y, { steps: 5 });
			await expect(blocks.nth(0)).toHaveClass(/dragging/);
			// A block's button losing a touch's capture to the gutter's is no release.
			await blocks.nth(0).getByRole("button").first().dispatchEvent("lostpointercapture");
			await expect(blocks.nth(0)).toHaveClass(/dragging/);
			await drop();
			await page.mouse.up();
			await expect(dragging, "the release ends the drag").toHaveCount(0);
			await restore();
			// A press held on one block takes no capture.
			await page.mouse.move(from.x, from.y);
			await page.mouse.down();
			await drop();
			await page.mouse.up();
			await page.mouse.move(to.x, to.y, { steps: 5 });
			await expect(dragging, "a move after the release drags nothing").toHaveCount(0);
			await restore();
			// Nor does a press with no move since the release.
			await page.mouse.move(from.x, from.y);
			await page.mouse.down();
			await drop();
			await page.mouse.up();
			await restore();
			await page.mouse.down({ button: "right" });
			await page.mouse.move(to.x, to.y, { steps: 5 });
			await expect(dragging, "a press after the release drags nothing").toHaveCount(0);
			await page.mouse.up({ button: "right" });
			await page.getByRole("button", { name: "Comment on commit message line 1" }).click();
			await expect(page.locator(".commit-msg-form .line-anchor"), "the click asks for its own line").toHaveText(["L1–1"]);
			await forms.getByRole("button", { name: /^Cancel$/ }).click();
			await expect(forms).toHaveCount(0);
		});

		await test.step("the Send Feedback shortcut does nothing while disconnected", async () => {
			// The global comment posted above lets the review send feedback.
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
			await drop();
			await page.keyboard.press("Control+Shift+Enter");
			await expect(sendFeedback).toHaveAttribute("data-clicks", "0");

			await restore();
			await page.keyboard.press("Control+Shift+Enter");
			await expect(page.locator("main.review.done")).toHaveCount(1);
		});
	} finally {
		// A failure before the release would leave the bundle's route waiting.
		release();
		await meerkat.kill();
	}
});

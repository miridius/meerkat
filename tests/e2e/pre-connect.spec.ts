// The page paints before LiveView joins, and a click made then never
// reaches the server. LiveViewTest renders no CSS and makes no clicks
// through the browser, so only a browser shows the page refusing them.
// This spec uses Playwright's own `test`: the one in ./lib/test waits
// for the join on every `goto`.
import { expect, test } from "@playwright/test";
import { startMeerkat } from "./lib/runner";

test("the page takes no clicks until LiveView connects, and says whether it is connecting", async ({ page }) => {
	const meerkat = await startMeerkat();
	// Holding back the app bundle holds the page at its first paint.
	let release = () => {};
	const held = new Promise<void>((resolve) => {
		release = resolve;
	});
	try {
		// Refusing both LiveView transports makes the first connect fail.
		let refuse = true;
		await page.routeWebSocket(/\/live\/websocket/, (ws) => (refuse ? ws.close() : ws.connectToServer()));
		await page.route(/\/live\/longpoll/, (route) => (refuse ? route.abort() : route.continue()));
		await page.route(/\/assets\/app-[^/]*\.js$/, async (route) => {
			await held;
			await route.continue();
		});
		await page.goto(meerkat.url, { waitUntil: "commit" });

		const root = page.locator("[data-phx-main]");
		const pill = page.locator(".conn-indicator");
		const approved = page.locator(".file-section").first().getByRole("checkbox", { name: "Approved" });
		const addGlobal = page.getByRole("button", { name: /^\+ Add global comment$/ });
		await expect(pill).toHaveText("connecting…", { useInnerText: true });

		// Real mouse clicks: Playwright's own `click` waits until the
		// element can take the click.
		const clickThrough = async () => {
			for (const control of [approved, addGlobal]) {
				const box = await control.boundingBox();
				if (!box) throw new Error("control has no box");
				await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
			}
		};
		await clickThrough();
		await expect(approved, "the click does not tick a box the server never hears of").not.toBeChecked();

		release();
		await expect(root).toHaveClass(/phx-client-error/);
		await expect(pill).toHaveText("disconnected", { useInnerText: true });
		await clickThrough();
		await expect(approved, "a failed connect leaves the page refusing clicks").not.toBeChecked();

		refuse = false;
		await expect(root).toHaveClass(/phx-connected/);
		await expect(pill).toHaveText("connected", { useInnerText: true });
		await expect(approved).not.toBeChecked();
		await expect(page.locator(".global-comments .comment-form")).toHaveCount(0);

		await addGlobal.click();
		await expect(page.locator(".global-comments .comment-form")).toHaveCount(1);
	} finally {
		// A failure before the release would leave the bundle's route waiting.
		release();
		await meerkat.kill();
	}
});

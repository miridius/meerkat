// Spec entry point. Extends `@playwright/test`'s `page` with a `goto`
// override that waits for Phoenix LiveView's WebSocket to be connected
// before returning, so the first interaction after navigation isn't
// racing against a disconnected socket. Cold-start phx-click events
// on a disconnected socket are dropped silently.

import { test as base, expect, type Page } from "@playwright/test";

type Fixtures = Record<string, never>;

declare global {
	interface Window {
		liveSocket?: { isConnected(): boolean };
	}
}

// Phoenix LV stamps the root-view wrapper (the element with
// `data-phx-main`) with `phx-connected` once the channel has joined — at
// that point phx-click handlers are bound. `liveSocket.isConnected()`
// reports only the WebSocket handshake, which fires earlier; we want the
// post-join state.
async function waitForLiveView(page: Page): Promise<void> {
	await page.waitForFunction(
		() => document.querySelector("[data-phx-main]")?.classList.contains("phx-connected") === true,
		undefined,
		{ timeout: 45_000 },
	);
}

// The `page` fixture's goto, for pages from `context.newPage()`, which
// navigate with the plain goto.
export async function gotoConnected(page: Page, url: string): Promise<void> {
	await page.goto(url);
	await waitForLiveView(page);
}

export const test = base.extend<Fixtures>({
	page: async ({ page }, use) => {
		const originalGoto = page.goto.bind(page);
		page.goto = (async (url, opts) => {
			const response = await originalGoto(url, opts);
			await waitForLiveView(page);
			return response;
		}) as typeof page.goto;
		await use(page);
	},
});

export { expect };

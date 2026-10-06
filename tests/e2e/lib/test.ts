// Spec entry point. Extends `@playwright/test`'s `page` with overrides
// for both `goto` and `reload`. After navigation, each waits for the
// LiveView channel to join (the root view gets `phx-connected`) before
// returning. A phx-click sent before the join is silently dropped;
// a click immediately after `page.reload` caused a flaky test.

import { test as base, expect } from "@playwright/test";

type Fixtures = Record<string, never>;

declare global {
	interface Window {
		liveSocket?: { isConnected(): boolean };
	}
}

export const test = base.extend<Fixtures>({
	page: async ({ page }, use) => {
		// Phoenix LV stamps the root-view wrapper (the element with
		// `data-phx-main`) with `phx-connected` once the channel has
		// joined — at that point phx-click handlers are bound.
		// `liveSocket.isConnected()` reports only the WebSocket
		// handshake, which fires earlier; we want the post-join
		// state.
		const joined = () =>
			page.waitForFunction(
				() => document.querySelector("[data-phx-main]")?.classList.contains("phx-connected") === true,
				undefined,
				{ timeout: 45_000 },
			);
		const originalGoto = page.goto.bind(page);
		page.goto = (async (url, opts) => {
			const response = await originalGoto(url, opts);
			await joined();
			return response;
		}) as typeof page.goto;
		const originalReload = page.reload.bind(page);
		page.reload = (async (opts) => {
			const response = await originalReload(opts);
			await joined();
			return response;
		}) as typeof page.reload;
		await use(page);
	},
});

export { expect };

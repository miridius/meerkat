// Controls LiveView's transports on a page: while refusing, every new
// WebSocket or long-poll request fails; `drop()` also closes the open
// WebSocket and starts refusing. While holding, the WebSocket loses
// every message the page sends. Call before the page's `goto`.
import type { Page, WebSocketRoute } from "@playwright/test";

export async function liveTransports(page: Page) {
	let refusing = false;
	let holding = false;
	let open: WebSocketRoute | null = null;
	await page.routeWebSocket(/\/live\/websocket/, (ws) => {
		if (refusing) return ws.close();
		const server = ws.connectToServer();
		ws.onMessage((message) => {
			if (!holding) server.send(message);
		});
		open = ws;
	});
	await page.route(/\/live\/longpoll/, (route) => (refusing ? route.abort() : route.continue()));
	return {
		refuse: (on: boolean) => {
			refusing = on;
		},
		hold: (on: boolean) => {
			holding = on;
		},
		drop: async () => {
			refusing = true;
			await open?.close();
		},
	};
}

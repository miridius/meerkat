import { createServer, type Server } from "node:net";
import { startMeerkat } from "./lib/runner";
import { expect, test } from "./lib/test";

// Keep an OS-assigned loopback listener open to stand in for another
// process holding a review's stable port.
async function occupyPort(): Promise<{ port: number; server: Server }> {
	const server = createServer();
	await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
	const address = server.address();
	if (address === null || typeof address === "string") throw new Error("no port bound");
	return { port: address.port, server };
}

async function freePort(): Promise<number> {
	const { port, server } = await occupyPort();
	await new Promise((resolve) => server.close(resolve));
	return port;
}

function portOf(url: string): number {
	return Number(new URL(url).port);
}

test.describe("the port a review is served on", () => {
	test("without --port, a review binds its stable port, or another port while another review holds it", async ({
		page,
	}) => {
		const stable = await freePort();
		const env = { MEERKAT_PORT: String(stable) };
		const holder = await startMeerkat({ port: null, env });
		try {
			expect(portOf(holder.url), "a free stable port is the one served on").toBe(stable);

			const runner = await startMeerkat({ port: null, env });
			try {
				expect(portOf(runner.url)).not.toBe(stable);
				await page.goto(runner.url);
				await page.getByRole("button", { name: /^Approve$/ }).click();
				const { code, stderr } = await runner.awaitExit();
				expect(code).toBe(0);
				expect(stderr).toContain(`port ${stable} is in use; serving on ${runner.url}`);
			} finally {
				await runner.kill();
			}
		} finally {
			await holder.kill();
		}
	});

	test("an explicit --port that is taken fails to start and names the port", async () => {
		const { port, server } = await occupyPort();
		try {
			const runner = await startMeerkat({ port, awaitUrl: false });
			try {
				const { code, stderr } = await runner.awaitExit();
				// 64, a rejected argument.
				expect(code).toBe(64);
				expect(stderr).toContain(`meerkat: port ${port} is in use (--port ${port})`);
				expect(stderr).not.toContain("Paused for human review");
			} finally {
				await runner.kill();
			}
		} finally {
			server.close();
		}
	});
});

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
	test("without --port, a review binds its stable port", async ({ page }) => {
		const stable = await freePort();
		const runner = await startMeerkat({ port: null, env: { MEERKAT_PORT: String(stable) } });
		try {
			expect(portOf(runner.url)).toBe(stable);
			await page.goto(runner.url);
		} finally {
			await runner.kill();
		}
	});

	test("--port 0 binds an OS-assigned port, not the review's stable port", async ({ page }) => {
		const { port: stable, server } = await occupyPort();
		try {
			const runner = await startMeerkat({ port: 0, env: { MEERKAT_PORT: String(stable) } });
			try {
				expect(portOf(runner.url)).not.toBe(stable);
				await page.goto(runner.url);
				await page.getByRole("button", { name: /^Approve$/ }).click();
				const { code, stderr } = await runner.awaitExit();
				expect(code).toBe(0);
				// A launcher that still preferred the occupied stable port would
				// also land elsewhere, but only after this fallback warning.
				expect(stderr).not.toContain("is in use");
			} finally {
				await runner.kill();
			}
		} finally {
			server.close();
		}
	});

	test("a review whose stable port is taken is served on another port", async ({ page }) => {
		const { port: stable, server } = await occupyPort();
		try {
			const runner = await startMeerkat({ port: null, env: { MEERKAT_PORT: String(stable) } });
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
			server.close();
		}
	});

	test("an invalid MEERKAT_PORT is reported and the review is served on an OS-assigned port", async ({
		page,
	}) => {
		const runner = await startMeerkat({ port: null, env: { MEERKAT_PORT: "abc" } });
		try {
			await page.goto(runner.url);
			await page.getByRole("button", { name: /^Approve$/ }).click();
			const { code, stderr } = await runner.awaitExit();
			expect(code).toBe(0);
			expect(stderr).toContain('meerkat: ignoring MEERKAT_PREFERRED_PORT="abc": not a port from 1 to 65535');
		} finally {
			await runner.kill();
		}
	});

	test("an explicit --port that is taken fails to start and names the port", async () => {
		const { port, server } = await occupyPort();
		try {
			const runner = await startMeerkat({ port, awaitUrl: false });
			try {
				const { code, stderr } = await runner.awaitExit();
				// 64, a rejected argument, so the dev launcher exits instead of
				// waiting for a source change as it does after a crash.
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

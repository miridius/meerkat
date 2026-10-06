import { expect, test } from "./lib/test";
import { startMeerkat } from "./lib/runner";

function secondsLeft(text: string | null): number {
	const match = /^(\d{2}):(\d{2}) left$/.exec(text ?? "");
	if (!match) throw new Error(`countdown text is not mm:ss left: ${text}`);
	return Number(match[1]) * 60 + Number(match[2]);
}

// The seam is the Countdown hook ticking in the browser from the deadline
// the server renders. What it shows for a given time left, the warning
// and urgent thresholds and the time over, is covered by
// assets/ts/countdown.test.ts.
test.describe("review countdown", () => {
	test("counts down towards the review's timeout in the footer", async ({ page }) => {
		const meerkat = await startMeerkat({
			env: { MEERKAT_REVIEW_TIMEOUT: "45" },
		});
		try {
			await page.goto(meerkat.url);
			const countdown = page.locator(".review-countdown");

			await expect(
				countdown,
				"the footer shows the time left before the review times out",
			).toHaveText(/^\d{2}:\d{2} left$/);

			const first = secondsLeft(await countdown.textContent());
			expect(first, "a 45 second limit starts the clock just under 45 seconds").toBeGreaterThan(30);
			expect(first, "the clock never starts above the limit").toBeLessThanOrEqual(45);

			await expect
				.poll(async () => secondsLeft(await countdown.textContent()), {
					message: "the clock runs down rather than up or nowhere",
				})
				.toBeLessThan(first);

			await expect(
				countdown,
				"under one minute left the countdown is styled as urgent",
			).toHaveClass(/urgent/);
		} finally {
			await meerkat.kill();
		}
	});
});

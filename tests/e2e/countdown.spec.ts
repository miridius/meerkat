import { expect, test } from "./lib/test";
import { startMeerkat } from "./lib/runner";

function secondsLeft(text: string | null): number {
	const match = /^(\d{2}):(\d{2}) left$/.exec(text ?? "");
	if (!match) throw new Error(`countdown text is not mm:ss left: ${text}`);
	return Number(match[1]) * 60 + Number(match[2]);
}

test.describe("review countdown", () => {
	test("counts down towards the review's timeout", async ({
		page,
	}) => {
		const meerkat = await startMeerkat({
			env: { MEERKAT_REVIEW_TIMEOUT: "1800" },
		});
		try {
			await page.goto(meerkat.url);
			const countdown = page.locator(".review-countdown");

			await expect(
				countdown,
				"the footer shows the time left before the review times out",
			).toHaveText(/^\d{2}:\d{2} left$/);

			const first = secondsLeft(await countdown.textContent());
			expect(
				first,
				"a 1800 second limit starts the clock just under 30 minutes",
			).toBeGreaterThan(1740);
			expect(first, "the clock never starts above the limit").toBeLessThanOrEqual(
				1800,
			);

			await expect
				.poll(async () => secondsLeft(await countdown.textContent()), {
					message: "the clock runs down rather than up or nowhere",
					timeout: 5000,
				})
				.toBeLessThan(first);

			await expect(
				countdown,
				"a 30 minute review is not styled as running out with 29 minutes left",
			).not.toHaveClass(/warn|urgent/);
		} finally {
			await meerkat.kill();
		}
	});

	test("turns amber under five minutes and red under one", async ({ page }) => {
		const meerkat = await startMeerkat({
			env: { MEERKAT_REVIEW_TIMEOUT: "240" },
		});
		try {
			await page.goto(meerkat.url);
			await expect(
				page.locator(".review-countdown"),
				"under five minutes left the countdown is styled as a warning",
			).toHaveClass(/warn/);
		} finally {
			await meerkat.kill();
		}

		const urgent = await startMeerkat({
			env: { MEERKAT_REVIEW_TIMEOUT: "45" },
		});
		try {
			await page.goto(urgent.url);
			await expect(
				page.locator(".review-countdown"),
				"under one minute left the countdown is styled as urgent",
			).toHaveClass(/urgent/);
		} finally {
			await urgent.kill();
		}
	});
});

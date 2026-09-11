import { makeFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";
import { expect, test } from "./lib/test";

const LONG_BRANCH =
	"feature/queue-depth-metrics-and-per-partition-age-breakdown";
const SHORT_BRANCH = "fix/typo";

function branchFixture(branch: string) {
	const fixture = makeFixture();
	fixture.git("branch", "-m", branch);
	return fixture;
}

function chipValue(page: import("@playwright/test").Page) {
	return page.evaluate(() => {
		const value = document.querySelector(
			".branch-chip .chip-value",
		) as HTMLElement;
		const toolbar = document.querySelector(".diff-toolbar") as HTMLElement;
		return {
			text: value.textContent,
			title: value.getAttribute("title"),
			clipped: value.offsetWidth < value.scrollWidth,
			toolbarH: Math.round(toolbar.getBoundingClientRect().height),
		};
	});
}

test.describe("branch chip", () => {
	test("a branch name too long for the chip is clipped, and hovering it shows the whole name", async ({
		page,
	}) => {
		const meerkat = await startMeerkat({ fixture: branchFixture(LONG_BRANCH) });
		try {
			await page.setViewportSize({ width: 1500, height: 800 });
			await page.goto(meerkat.url);
			await expect(page.locator(".branch-chip")).toBeVisible();

			const chip = await chipValue(page);

			expect(
				chip.clipped,
				"the chip renders less of the branch name than the name holds",
			).toBe(true);
			expect(
				chip.title,
				"the whole branch name is on the tooltip, so hovering recovers what the chip cut",
			).toBe(LONG_BRANCH);
			expect(
				chip.toolbarH,
				"the capped chip leaves the toolbar on one row at 1500px",
			).toBe(41);
		} finally {
			await meerkat.kill();
		}
	});

	test("a branch name that fits is shown whole", async ({ page }) => {
		const meerkat = await startMeerkat({ fixture: branchFixture(SHORT_BRANCH) });
		try {
			await page.setViewportSize({ width: 1500, height: 800 });
			await page.goto(meerkat.url);
			await expect(page.locator(".branch-chip")).toBeVisible();

			const chip = await chipValue(page);

			expect(
				chip.clipped,
				"the cap is wide enough to leave an ordinary branch name intact",
			).toBe(false);
			expect(chip.text, "the chip carries the branch name").toBe(SHORT_BRANCH);
		} finally {
			await meerkat.kill();
		}
	});
});

import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "./lib/test";
import { startMeerkat } from "./lib/runner";

// Point Meerkat.Version at a baked manifest by setting RELEASE_ROOT (a
// dev BEAM reads the same file a prod release would), so the chip renders
// a real version + changelog without needing an installed release.
function manifestRoot(lines: string[]): string {
	const root = mkdtempSync(join(tmpdir(), "meerkat-rr-"));
	writeFileSync(join(root, "meerkat_version"), `${lines.join("\n")}\n`);
	return root;
}

const PROD_MANIFEST = [
	"abc1234567890",
	"https://github.com/miridius/meerkat",
	"Live-restart a review onto a newly-installed version (#11)",
	"Install versioned releases (#10)",
];

test.describe("version chip", () => {
	test("a dev build shows a dev label and no changelog", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);
			const chip = page.locator(".version-chip-btn");
			await expect(chip.locator(".chip-value")).toHaveText(/^dev: /);
			await expect(chip).toBeDisabled();
		} finally {
			await meerkat.kill();
		}
	});

	test("a prod build shows the version and a changelog popover", async ({ page }) => {
		const releaseRoot = manifestRoot(PROD_MANIFEST);
		const meerkat = await startMeerkat({ env: { RELEASE_ROOT: releaseRoot } });
		try {
			await page.goto(meerkat.url);
			const chip = page.locator(".version-chip-btn");
			await expect(chip.locator(".chip-value")).toHaveText("abc1234");
			await expect(page.locator(".version-popover")).toBeHidden();

			await chip.click();
			const popover = page.locator(".version-popover");
			await expect(popover).toBeVisible();
			await expect(
				popover.getByRole("link", { name: /#11.*Live-restart/ }),
			).toHaveAttribute("href", "https://github.com/miridius/meerkat/pull/11");
			await expect(popover.getByRole("link", { name: /#10/ })).toBeVisible();
		} finally {
			await meerkat.kill();
			rmSync(releaseRoot, { recursive: true, force: true });
		}
	});

	test("the badge counts entries newer than last seen and clears on open", async ({ page }) => {
		const releaseRoot = manifestRoot(PROD_MANIFEST);
		const meerkat = await startMeerkat({ env: { RELEASE_ROOT: releaseRoot } });
		try {
			await page.goto(meerkat.url);
			// First visit treats the current version as seen: no badge.
			await expect(page.locator(".version-badge")).toBeHidden();

			// Simulate having last acknowledged up to #10, then re-mount.
			await page.evaluate(() => localStorage.setItem("meerkat:lastSeenPr", "10"));
			await page.reload();
			const badge = page.locator(".version-badge");
			await expect(badge).toBeVisible();
			await expect(badge).toHaveText("1");

			await page.locator(".version-chip-btn").click();
			await expect(badge).toBeHidden();
		} finally {
			await meerkat.kill();
			rmSync(releaseRoot, { recursive: true, force: true });
		}
	});
});

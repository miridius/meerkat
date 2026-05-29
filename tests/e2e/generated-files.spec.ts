import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test } from "./lib/test";
import { makeFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";

test.describe("linguist-generated file visibility", () => {
	test("UI hides generated files by default; toggle reveals them", async ({ page }) => {
		// Stage one normal file + one file marked
		// `linguist-generated=true` via committed `.gitattributes`.
		// The mixed-set path does NOT auto-approve (only all-generated
		// or all-approved+generated does), so the UI opens — and the
		// pre-port behaviour was to hide the generated file from the
		// main list by default.
		const fixture = makeFixture({ files: {} });
		try {
			fixture.git("config", "user.email", "t@t.t");
			fixture.git("config", "user.name", "t");
			writeFileSync(
				join(fixture.dir, ".gitattributes"),
				"bun.lock linguist-generated=true\n",
			);
			fixture.git("add", ".gitattributes");
			fixture.git("commit", "-q", "-m", "seed attrs");

			writeFileSync(join(fixture.dir, "bun.lock"), "fresh lockfile contents\n");
			writeFileSync(join(fixture.dir, "src.ts"), "export const greeting = 'hi';\n");
			fixture.git("add", "bun.lock", "src.ts");

			const meerkat = await startMeerkat({ fixture });
			try {
				await page.goto(meerkat.url);

				const srcHeader = page.getByRole("button", { name: /^▾ A src\.ts$/ });
				const lockHeader = page.getByRole("button", { name: /^▾ A bun\.lock$/ });

				// src.ts visible; bun.lock hidden by default.
				await expect(srcHeader).toBeVisible();
				await expect(lockHeader).toBeHidden();

				// File-filter sidebar is closed by default — open it
				// to reach the generated-files chip. Button's
				// accessible name is the aria-label, not the "☰ Files"
				// content.
				await page.getByRole("button", { name: /^Toggle file list$/ }).click();
				await expect(page.locator(".file-filter")).toBeVisible();

				// Sidebar shows a "generated ×" chip when generated
				// files exist but are hidden. Clicking the chip flips
				// `show_generated` and the label becomes "generated ✓".
				const chip = page.locator(".file-filter .filter-chip", {
					hasText: "generated",
				});
				await expect(chip).toContainText("generated");
				await expect(chip).toContainText("×");

				await chip.click();
				await expect(chip).toContainText("✓");
				await expect(lockHeader).toBeVisible();
				await expect(srcHeader).toBeVisible();

				// Clicking again restores the default.
				await chip.click();
				await expect(chip).toContainText("×");
				await expect(lockHeader).toBeHidden();
				await expect(srcHeader).toBeVisible();
			} finally {
				await meerkat.kill();
			}
		} finally {
			fixture.cleanup();
		}
	});

	test("main.review uses full viewport width (no max-width cap)", async ({ page }) => {
		// The pre-port SvelteKit UI went full-viewport explicitly. The
		// BEAM port shipped a 1400px max-width cap that wasted roughly
		// half a 1920px screen and forced wrap on lines that would
		// otherwise have fit. Lock down full-width via a real viewport
		// check.
		const meerkat = await startMeerkat();
		try {
			await page.setViewportSize({ width: 1920, height: 1200 });
			await page.goto(meerkat.url);

			const main = page.locator("main.review");
			await expect(main).toBeVisible();

			const { computedMaxWidth, clientWidth, viewportWidth } = await main.evaluate(
				(el) => ({
					computedMaxWidth: getComputedStyle(el).maxWidth,
					clientWidth: (el as HTMLElement).clientWidth,
					viewportWidth: window.innerWidth,
				}),
			);

			expect(computedMaxWidth).toBe("none");
			// Allow for the side padding on `main.review` (currently
			// 16px each side). Anything inside ~80% of viewport is the
			// regression — the old cap was 1400px on a 1920 screen
			// (~73%).
			expect(clientWidth).toBeGreaterThan(viewportWidth * 0.95);
		} finally {
			await meerkat.kill();
		}
	});
});

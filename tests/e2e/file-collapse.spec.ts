import { makeFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";
import { afterNextFrame, expect, test } from "./lib/test";

// The browser seams of collapsing a file, by a click on its header, by
// approving it or by the filter: a form it hides stays mounted for the
// footer's link to scroll to and focus, and collapsing scrolls the next
// file's header to where it sticks, so scrolling on leaves it in place.
// Which file is next, when the scroll is pushed, which forms are open and
// the footer that lists them are covered by the LiveView tests.

const TALL_FILE = `${Array.from({ length: 400 }, (_, i) => `line ${i + 1}`).join("\n")}\n`;

test("a footer link scrolls to and focuses a form hidden by approving its file or by the filter, and collapsing or approving a file lands the next file's header where it sticks", async ({
	page,
}) => {
	const meerkat = await startMeerkat({
		fixture: makeFixture({ files: { "a.txt": TALL_FILE, "b.txt": TALL_FILE, "c.txt": TALL_FILE } }),
	});
	try {
		await page.goto(meerkat.url);
		const section = (name: string) => page.locator(".file-section", { hasText: name });
		const newLine = (name: string, n: number) => section(name).locator(`td.diff-line-num span[data-line-new-num="${n}"]`);

		await test.step("a footer link reaches a form hidden by approving its file or by the filter", async () => {
			const footer = page.locator(".decision-footer");
			const link = footer.getByRole("button", { name: "a.txt L2" });
			const form = section("a.txt").locator('tr.meerkat-form-row[data-meerkat-form-anchor="2"] .comment-form');

			await newLine("a.txt", 2).click();
			await form.locator("textarea").fill("hidden");
			await page.getByRole("button", { name: /^\+ Add global comment$/ }).click();

			await section("a.txt").getByRole("checkbox", { name: "Approved" }).click();
			await expect(form).toHaveCount(0);
			await expect(footer).toContainText("2 unsaved forms open:");
			await expect(footer.getByRole("button", { name: "Global" })).toBeVisible();
			await link.click();
			await expect(form).toBeInViewport();
			await expect(form.locator("textarea")).toHaveValue("hidden");
			await expect(form.locator("textarea")).toBeFocused();

			// Hiding the first two files moves the third to the top of the list.
			await page.getByRole("button", { name: /^Toggle file list$/ }).click();
			await page.locator(".file-filter .filter-input").fill("c.txt");
			await expect(section("a.txt")).toHaveCount(0);
			await expect(section("b.txt")).toHaveCount(0);
			await link.click();
			await expect(form).toBeInViewport();
			await expect(form.locator("textarea")).toHaveValue("hidden");
			// Every file shown again renders its diff, not a blank section.
			for (const name of ["a.txt", "b.txt", "c.txt"]) {
				await expect(newLine(name, 1)).toBeAttached();
			}

			await form.getByRole("button", { name: /^Cancel$/ }).click();
			await page
				.locator(".global-comments")
				.getByRole("button", { name: /^Cancel$/ })
				.click();
			await expect(footer.locator(".dirty-marker")).toHaveCount(0);
		});

		await test.step("collapsing or approving a file lands the next file's header where it sticks", async () => {
			// The header's top against its sticky top, while its section's top
			// edge sits right above it, so the header is not stuck yet.
			const landed = (name: string) =>
				section(name).evaluate((s) => {
					const header = s.querySelector(".file-section-header");
					if (!header) return false;
					const top = header.getBoundingClientRect().top;
					const sticky = Number.parseFloat(getComputedStyle(header).top);
					return Math.abs(top - sticky) < 0.5 && Math.abs(s.getBoundingClientRect().top + s.clientTop - top) < 0.5;
				});
			const settled = async (name: string) => {
				await expect.poll(() => landed(name)).toBe(true);
				// The smooth scroll ends there rather than passing through.
				await afterNextFrame(page);
				expect(await landed(name)).toBe(true);
			};

			// Deep inside a.txt, its header is stuck under the toolbar.
			await page.evaluate(() => window.scrollTo(0, 1500));
			const aHeader = section("a.txt").getByRole("button", { name: /a\.txt/ });
			await aHeader.click();
			await expect(section("a.txt")).toHaveClass(/collapsed/);
			await settled("b.txt");
			// The scroll leaves focus where it was, unlike a pick in the files
			// dropdown.
			await expect(aHeader).toBeFocused();

			await section("b.txt").getByRole("checkbox", { name: "Approved" }).click();
			await expect(section("b.txt")).toHaveClass(/collapsed/);
			await settled("c.txt");
		});
	} finally {
		await meerkat.kill();
	}
});

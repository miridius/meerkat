import { makeFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";
import { afterNextFrame, expect, test } from "./lib/test";

// Playwright's headless Chromium hides every scrollbar unless told not to.
test.use({ launchOptions: { ignoreDefaultArgs: ["--hide-scrollbars"] } });

// macOS's default overlay scrollbars take no room and show only while
// scrolling. The tree's styled scrollbar is always drawn, 10px wide, where
// a classic one is 15px.
test("the files dropdown's tree draws a scrollbar each way it scrolls, and none when it fits; its rows span it and highlight on hover", async ({
	page,
}) => {
	const files: Record<string, string> = { [`${"long_name_".repeat(12)}.txt`]: "x\n" };
	for (let i = 10; i < 70; i++) files[`dir/file_${i}.txt`] = "x\n";
	const meerkat = await startMeerkat({ fixture: makeFixture({ files }) });
	try {
		await page.setViewportSize({ width: 700, height: 500 });
		await page.goto(meerkat.url);
		await page.getByRole("button", { name: /^Toggle file list$/ }).click();
		const gutters = () =>
			page.locator(".file-tree-scroll").evaluate((el: HTMLElement) => ({
				vertical: el.offsetWidth - el.clientWidth,
				horizontal: el.offsetHeight - el.clientHeight,
			}));
		await expect.poll(gutters).toEqual({ vertical: 10, horizontal: 10 });

		// While the tree scrolls sideways, every row spans it, so the row
		// buttons keep to one column.
		const buttonRights = await page.locator(".file-entry").evaluateAll(
			(rows) =>
				new Set(rows.map((row) => Math.round([...row.querySelectorAll(".ghost-btn")].at(-1)?.getBoundingClientRect().right ?? 0)))
					.size,
		);
		expect(buttonRights).toBe(1);

		// A folder row highlights on hover with a file row's colour, which
		// the base button hover rule would otherwise overrule.
		const background = (el: Element) => getComputedStyle(el).backgroundColor;
		const file = page.locator(".file-entry").first();
		await file.hover();
		await expect.poll(() => file.evaluate(background)).not.toBe("rgba(0, 0, 0, 0)");
		await afterNextFrame(page);
		const highlight = await file.evaluate(background);
		const folder = page.locator(".tree-dir").first();
		await folder.hover();
		await expect.poll(() => folder.evaluate(background)).toBe(highlight);

		await page.getByRole("textbox", { name: "Filter files" }).fill("file_42");
		await expect.poll(gutters).toEqual({ vertical: 0, horizontal: 0 });
	} finally {
		await meerkat.kill();
	}
});

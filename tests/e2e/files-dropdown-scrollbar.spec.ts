import { makeFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";
import { expect, test } from "./lib/test";

// Playwright's headless Chromium hides every scrollbar unless told not to.
test.use({ launchOptions: { ignoreDefaultArgs: ["--hide-scrollbars"] } });

// macOS's default overlay scrollbars take no room and show only while
// scrolling. The tree's styled scrollbar is always drawn, 10px wide, where
// a classic one is 15px.
test("the files dropdown's tree draws a scrollbar each way it scrolls, and none when it fits", async ({
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

		await page.getByRole("textbox", { name: "Filter files" }).fill("file_42");
		await expect.poll(gutters).toEqual({ vertical: 0, horizontal: 0 });
	} finally {
		await meerkat.kill();
	}
});

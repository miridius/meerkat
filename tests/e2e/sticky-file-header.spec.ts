import type { Page } from "@playwright/test";
import { makeFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";
import { expect, test } from "./lib/test";

const TALL_FILE = `${Array.from({ length: 400 }, (_, i) => `line ${i + 1}`).join("\n")}\n`;

const ONE_ROW_WIDTH = 1500;
const ONE_ROW_H = 41; // measured; not --toolbar-h's 40px fallback
const WRAPPED_WIDTHS = [1150, 900, 600];

// A long commit subject, so the toolbar carries enough to wrap at the
// widths above.
function stickyFixture() {
	return makeFixture({
		commitMsg:
			"Auto-approve a review nobody answers within 30 minutes\n\nBody paragraph.\n",
		files: { "lib/tall.ex": TALL_FILE, "lib/second.ex": TALL_FILE },
	});
}

type Probe = {
	toolbarH: number;
	headerTop: number;
	hitCheckbox: boolean;
	hitTag: string | null;
};

function probe(page: Page): Promise<Probe> {
	return page.evaluate(() => {
		const toolbar = document.querySelector(".diff-toolbar") as HTMLElement;
		const header = document.querySelector(".file-section-header") as HTMLElement;
		const box = header.getBoundingClientRect();
		const checkbox = header.querySelector(
			'input[type="checkbox"]',
		) as HTMLElement;
		const cb = checkbox.getBoundingClientRect();
		const onTop = document.elementFromPoint(
			cb.left + cb.width / 2,
			cb.top + cb.height / 2,
		);
		return {
			toolbarH: Math.round(toolbar.getBoundingClientRect().height),
			headerTop: Math.round(box.top),
			hitCheckbox: onTop === checkbox,
			hitTag: onTop && `${onTop.tagName}.${onTop.className}`,
		};
	});
}

async function scrollDeepIntoTheFirstFile(page: Page) {
	await expect(page.getByRole("button", { name: /tall\.ex/ })).toBeVisible();
	await page.evaluate(() => window.scrollTo(0, 2500));
	await expect
		.poll(() => page.evaluate(() => Math.round(window.scrollY)))
		.toBeGreaterThan(2000);
}

test.describe("the file header stays readable while its diff scrolls", () => {
	test(`the toolbar fits one row at ${ONE_ROW_WIDTH}px and wraps at ${WRAPPED_WIDTHS.join("px and ")}px`, async ({
		page,
	}) => {
		const meerkat = await startMeerkat({ fixture: stickyFixture() });
		try {
			await page.goto(meerkat.url);
			await expect(page.getByRole("button", { name: /tall\.ex/ })).toBeVisible();

			await page.setViewportSize({ width: ONE_ROW_WIDTH, height: 800 });
			expect(
				(await probe(page)).toolbarH,
				"the widest case under test is the unwrapped toolbar the old hardcoded offset was written for",
			).toBe(ONE_ROW_H);

			for (const width of WRAPPED_WIDTHS) {
				await page.setViewportSize({ width, height: 800 });
				expect(
					(await probe(page)).toolbarH,
					`the toolbar is taller than one row at ${width}px, which is what the other cases rest on`,
				).toBeGreaterThan(ONE_ROW_H);
			}
		} finally {
			await meerkat.kill();
		}
	});

	for (const width of [ONE_ROW_WIDTH, ...WRAPPED_WIDTHS]) {
		test(`at ${width}px the pinned header is not covered by the toolbar`, async ({
			page,
		}) => {
			const meerkat = await startMeerkat({ fixture: stickyFixture() });
			try {
				await page.setViewportSize({ width, height: 800 });
				await page.goto(meerkat.url);
				await scrollDeepIntoTheFirstFile(page);

				const probed = await probe(page);

				expect(
					probed.hitCheckbox,
					`the pinned header's approve checkbox is the topmost element at its own centre, not ${probed.hitTag}`,
				).toBe(true);
				expect(
					probed.headerTop,
					"the pinned file header sits directly below the toolbar, however many rows the toolbar wrapped onto",
				).toBe(probed.toolbarH);
			} finally {
				await meerkat.kill();
			}
		});
	}

	test("narrowing the window while the review is open re-pins the header", async ({
		page,
	}) => {
		const meerkat = await startMeerkat({ fixture: stickyFixture() });
		try {
			await page.setViewportSize({ width: ONE_ROW_WIDTH, height: 800 });
			await page.goto(meerkat.url);
			await scrollDeepIntoTheFirstFile(page);

			const wide = await probe(page);
			expect(wide.headerTop).toBe(wide.toolbarH);

			await page.setViewportSize({ width: 900, height: 800 });
			await expect
				.poll(async () => (await probe(page)).toolbarH, {
					message: "the toolbar wrapped onto more rows as the window narrowed",
				})
				.toBeGreaterThan(wide.toolbarH);

			const narrow = await probe(page);
			expect(
				narrow.headerTop,
				"the header follows the toolbar's new height without a reload",
			).toBe(narrow.toolbarH);
			expect(
				narrow.hitCheckbox,
				`the approve checkbox is still the topmost element at its own centre, not ${narrow.hitTag}`,
			).toBe(true);
		} finally {
			await meerkat.kill();
		}
	});

	test("the header is pinned correctly on the first paint, before any hook mounts", async ({
		page,
	}) => {
		const meerkat = await startMeerkat({ fixture: stickyFixture() });
		// Its own page: ./lib/test's `goto` waits for LiveView to join,
		// which cannot happen with the bundle blocked.
		const bare = await page.context().newPage();
		try {
			await bare.route("**/assets/app-*.js", (route) => route.abort());
			await bare.setViewportSize({ width: 900, height: 800 });
			await bare.goto(meerkat.url);
			await expect(bare.locator(".diff-toolbar")).toBeVisible();

			const published = await bare.evaluate(() => {
				const toolbar = document.querySelector(".diff-toolbar") as HTMLElement;
				return {
					toolbarH: Math.round(toolbar.getBoundingClientRect().height),
					published: document.documentElement.style
						.getPropertyValue("--toolbar-h")
						.trim(),
					hookMounted: !!window.liveSocket,
				};
			});

			expect(
				published.hookMounted,
				"the bundle that carries the ToolbarHeight hook never loaded",
			).toBe(false);
			expect(
				published.toolbarH,
				"the width under test is one where the CSS fallback would be wrong",
			).toBeGreaterThan(ONE_ROW_H);
			expect(
				published.published,
				"--toolbar-h already carries the toolbar's real height",
			).toBe(`${published.toolbarH}px`);
		} finally {
			await bare.close();
			await meerkat.kill();
		}
	});
});

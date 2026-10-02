import { writeFileSync } from "node:fs";
import { join } from "node:path";
import type { BrowserContext, Page } from "@playwright/test";
import { expect, test } from "./lib/test";
import { startMeerkat } from "./lib/runner";
import { makeFixture } from "./lib/fixture";

// Every tab of a review shows the same thing. What the LiveView holds
// is covered by the LiveView tests; these cover what the browser holds:
// hunk expansion inside @git-diff-view, the typed contents of a
// comment form, a drag still in progress, the scroll position, and the
// filter text in the tab that typed it.

async function openTab(context: BrowserContext, url: string): Promise<Page> {
	const tab = await context.newPage();
	await tab.goto(url);
	await tab.waitForFunction(
		() => document.querySelector("[data-phx-main]")?.classList.contains("phx-connected") === true,
	);
	return tab;
}

// One 80-line file edited at lines 20 and 60, so lines between the two
// hunks start hidden behind an Expand All button, and enough further
// files that the page scrolls well past the first.
function tallFixture() {
	const lines = (edit: boolean) => {
		const body = Array.from({ length: 80 }, (_, i) => {
			const n = i + 1;
			if (edit && n === 20) return "line twenty";
			if (edit && n === 60) return "line sixty";
			return `line ${n}`;
		});
		return `${body.join("\n")}\n`;
	};
	const fixture = makeFixture({ files: { "a.txt": lines(false) } });
	fixture.git("commit", "-q", "-m", "base");
	writeFileSync(join(fixture.dir, "a.txt"), lines(true));
	for (let f = 0; f < 6; f++) {
		const body = Array.from({ length: 60 }, (_, i) => `file ${f} line ${i}`).join("\n");
		writeFileSync(join(fixture.dir, `more${f}.txt`), `${body}\n`);
	}
	fixture.git("add", ".");
	return fixture;
}

test.describe("tabs in sync", () => {
	test("a hunk expanded in one tab is expanded in the other and in a tab opened later", async ({
		page,
		context,
	}) => {
		const meerkat = await startMeerkat({ fixture: tallFixture() });
		try {
			await page.goto(meerkat.url);
			const other = await openTab(context, meerkat.url);
			const line40 = (p: Page) =>
				p
					.locator(".file-section")
					.filter({ hasText: "a.txt" })
					.getByText("line 40", { exact: true })
					.first();
			await expect(line40(other)).toBeHidden();

			await page
				.locator(".file-section")
				.filter({ hasText: "a.txt" })
				.locator('button[title="Expand All"]')
				.filter({ visible: true })
				.click();
			await expect(line40(page)).toBeVisible();
			await expect(line40(other)).toBeVisible();

			const later = await openTab(context, meerkat.url);
			await expect(line40(later)).toBeVisible();
		} finally {
			await meerkat.kill();
		}
	});

	test("what is typed into a comment form shows in the other tab and in a tab opened later", async ({
		page,
		context,
	}) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);
			const other = await openTab(context, meerkat.url);

			await page.getByRole("button", { name: /^\+ Add global comment$/ }).click();
			const form = (p: Page) => p.locator(".comment-form");
			await form(page).locator("textarea").fill("typed in the first tab");
			await form(page).getByRole("button", { name: /^Question$/ }).click();
			await form(page).getByLabel("Please learn from this").check();

			for (const tab of [other, await openTab(context, meerkat.url)]) {
				await expect(form(tab).locator("textarea")).toHaveValue("typed in the first tab");
				await expect(form(tab).getByRole("button", { name: /^Question$/ })).toHaveClass(/active/);
				await expect(form(tab).getByLabel("Please learn from this")).toBeChecked();
			}

			await form(other).locator("textarea").fill("then edited in the second");
			await expect(form(page).locator("textarea")).toHaveValue("then edited in the second");
		} finally {
			await meerkat.kill();
		}
	});

	test("fast typing in a comment form with three tabs open loses nothing in any tab", async ({
		page,
		context,
	}) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);
			const others = [await openTab(context, meerkat.url), await openTab(context, meerkat.url)];
			// A busy tab is slow to handle each change from the typing tab.
			const cdp = await context.newCDPSession(others[0]);
			await cdp.send("Emulation.setCPUThrottlingRate", { rate: 20 });
			await page.bringToFront();
			await page.getByRole("button", { name: /^\+ Add global comment$/ }).click();
			const text = "the quick brown fox jumps over the lazy dog";
			await page.locator(".comment-form textarea").focus();
			await page.keyboard.type(text);
			await page.waitForTimeout(1000);
			for (const tab of [page, ...others]) {
				await expect(tab.locator(".comment-form textarea")).toHaveValue(text);
			}
		} finally {
			await meerkat.kill();
		}
	});

	test("the settings popover and a dismissed tip show in the other tab and in a tab opened later", async ({
		page,
		context,
	}) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);
			const other = await openTab(context, meerkat.url);

			await page.locator(".toolbar-settings > summary").click();
			await page.getByRole("button", { name: "Dismiss hint" }).click();

			for (const tab of [other, await openTab(context, meerkat.url)]) {
				await expect(tab.locator(".toolbar-settings")).toHaveAttribute("open", "");
				await expect(tab.locator("#meerkat-hint")).toHaveCount(0);
			}
		} finally {
			await meerkat.kill();
		}
	});

	test("a drag in progress and the scroll position show in the other tab", async ({
		page,
		context,
	}) => {
		const meerkat = await startMeerkat({ fixture: tallFixture() });
		try {
			await page.goto(meerkat.url);
			const other = await openTab(context, meerkat.url);

			const file = (p: Page) => p.locator(".file-section").filter({ hasText: "a.txt" });
			const gutter = file(page).locator("td.diff-line-new-num");
			await gutter.nth(0).hover();
			await page.mouse.down();
			await gutter.nth(2).hover();
			await expect(file(other).locator("td.drag-selecting")).toHaveCount(3);
			await page.mouse.up();
			await expect(file(other).locator("td.drag-selecting")).toHaveCount(0);
			await page.locator(".comment-form").getByRole("button", { name: /^Cancel$/ }).click();

			const last = (p: Page) => p.locator(".file-section").last();
			await last(page).scrollIntoViewIfNeeded();
			await expect(last(other)).toBeInViewport();
			await expect(other.locator(".file-section").first()).not.toBeInViewport();

			// Reloading a tab doesn't move the others.
			const y = await page.evaluate(() => window.scrollY);
			await other.reload();
			await expect(last(other)).toBeInViewport();
			await page.waitForTimeout(500);
			expect(await page.evaluate(() => window.scrollY)).toBe(y);
		} finally {
			await meerkat.kill();
		}
	});

	test("closing a tab mid-drag clears its highlight in the other tab", async ({ page, context }) => {
		const meerkat = await startMeerkat({ fixture: tallFixture() });
		try {
			await page.goto(meerkat.url);
			const dragger = await openTab(context, meerkat.url);
			const file = (p: Page) => p.locator(".file-section").filter({ hasText: "a.txt" });
			const gutter = file(dragger).locator("td.diff-line-new-num");
			await gutter.nth(0).hover();
			await dragger.mouse.down();
			await gutter.nth(2).hover();
			await expect(file(page).locator("td.drag-selecting")).toHaveCount(3);
			await dragger.close();
			await expect(file(page).locator("td.drag-selecting")).toHaveCount(0);
		} finally {
			await meerkat.kill();
		}
	});

	test("a filter change in one tab shows in the box of the tab that typed it", async ({
		page,
		context,
	}) => {
		const meerkat = await startMeerkat({ fixture: tallFixture() });
		try {
			await page.goto(meerkat.url);
			const other = await openTab(context, meerkat.url);
			// The tab that typed the filter keeps focus in the box while
			// another tab changes it.
			await page.bringToFront();
			await page.locator('[phx-click="toolbar.toggle_files_panel"]').click();
			const filter = (p: Page) => p.locator("#file-filter .filter-input");
			await filter(page).fill("more");
			await expect(filter(other)).toHaveValue("more");
			await filter(other).fill("");
			await expect(filter(page)).toHaveValue("");

			// Retyping the last letter faster than the push leaves the shared
			// value as it was, and must not stop a later change to a value
			// typed along the way from showing.
			await filter(page).pressSequentially("app");
			await expect(filter(other)).toHaveValue("app");
			await filter(page).press("Backspace");
			await filter(page).press("p");
			await page.waitForTimeout(300);
			await filter(other).fill("ap");
			await expect(filter(page)).toHaveValue("ap");
		} finally {
			await meerkat.kill();
		}
	});
});

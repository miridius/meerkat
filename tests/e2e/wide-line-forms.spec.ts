import { writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Locator } from "@playwright/test";
import { makeFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";
import { afterNextFrame, expect, test } from "./lib/test";

// The browser seam of inline forms and comments beside a long line with
// Wrap off: the code scrolls sideways inside its side's scroll view, and
// DiffViewer.svelte's injected rows must keep their contents in that view.

const LONG = `${"x".repeat(600)}\n`;

function wideFixture() {
	const fixture = makeFixture({ files: { "wide.txt": `short\n${LONG}` } });
	fixture.git("commit", "-q", "-m", "base");
	writeFileSync(join(fixture.dir, "wide.txt"), `shorter\n${LONG}${LONG}`);
	fixture.git("add", "wide.txt");
	return fixture;
}

// How far each element pokes out past the left or right edge of the
// scroll view holding `inRow`, in px; 0 when it is fully in view.
async function overflowPastView(inRow: Locator, elements: Locator[]): Promise<number[]> {
	const view = inRow.locator("xpath=ancestor::*[contains(@class, 'diff-table-scroll-container')][1]");
	const v = await view.boundingBox();
	if (!v) throw new Error("no scroll view");
	return Promise.all(
		elements.map(async (el) => {
			const b = await el.boundingBox();
			if (!b) throw new Error("element not rendered");
			return Math.round(Math.max(0, v.x - b.x, b.x + b.width - (v.x + v.width)));
		}),
	);
}

// Scrolls the view holding `inRow` to one end and returns how far it
// scrolled, so a check can show the long line really made it scroll.
async function scrollViewTo(inRow: Locator, where: "start" | "end"): Promise<number> {
	return inRow.evaluate((row, where) => {
		const view = row.closest(".diff-table-scroll-container") as HTMLElement;
		view.scrollLeft = where === "start" ? 0 : view.scrollWidth;
		return view.scrollLeft;
	}, where);
}

test("with Wrap off, inline forms and comments stay in view beside a long line in Split and Unified views", async ({
	page,
}) => {
	const meerkat = await startMeerkat({ fixture: wideFixture() });
	try {
		await page.setViewportSize({ width: 450, height: 900 });
		await page.goto(meerkat.url);
		const file = page.locator(".file-section").filter({ hasText: "wide.txt" });
		// This narrow, the toolbar has moved Split / Unified and Wrap into the ⚙ popover.
		const settings = page.locator(".toolbar-settings > summary");
		const viewControls = page.locator(".toolbar-settings-popover .view-controls");
		const inSettings = async (control: Locator) => {
			await settings.click();
			await control.click();
			await settings.click();
		};
		// Located by CSS, as it is hidden once the popover closes.
		const wrap = viewControls.locator(".wrap-toggle input");
		await inSettings(wrap);
		await expect(wrap).not.toBeChecked();

		const views = [
			{ name: "Split", line: file.locator('td.diff-line-new-num:has(span[data-line-num="2"])') },
			{ name: "Unified", line: file.locator('td.diff-line-num span[data-line-new-num="3"]') },
		];
		for (const [i, { name, line }] of views.entries()) {
			await inSettings(viewControls.getByRole("button", { name, exact: true }));
			await line.click();
			const formRow = file.locator("tr.meerkat-form-row");
			const form = formRow.locator(".comment-form");
			await expect(form).toBeVisible();
			await expect(form.locator(".flags label")).toHaveCount(2);
			const controls = [
				form.locator(".btn-submit"),
				form.locator(".btn-cancel"),
				...(await form.locator(".flags label").all()),
			];
			expect(await scrollViewTo(formRow, "end"), `${name} view scrolls sideways`).toBeGreaterThan(0);
			for (const where of ["start", "end"] as const) {
				await scrollViewTo(formRow, where);
				await afterNextFrame(page);
				expect(await overflowPastView(formRow, controls), `${name} form controls, scrolled to ${where}`).toEqual(
					controls.map(() => 0),
				);
			}

			// A long unbreakable code span stays readable inside the view.
			await form.locator("textarea").fill(`${name} comment \`${"y".repeat(200)}\``);
			await form.locator(".btn-submit").click();
			const commentRow = file.locator("tr.meerkat-comment-row").filter({ hasText: `${name} comment` });
			await expect(commentRow).toBeVisible();
			const parts = [
				commentRow.getByRole("button", { name: "Edit" }),
				commentRow.getByRole("button", { name: "Remove" }),
				commentRow.locator(".comment-body code"),
			];
			for (const where of ["start", "end"] as const) {
				await scrollViewTo(commentRow, where);
				await afterNextFrame(page);
				expect(await overflowPastView(commentRow, parts), `${name} comment, scrolled to ${where}`).toEqual([0, 0, 0]);
			}
			await expect(file.locator("tr.meerkat-comment-row")).toHaveCount(i + 1);
		}
	} finally {
		await meerkat.kill();
	}
});

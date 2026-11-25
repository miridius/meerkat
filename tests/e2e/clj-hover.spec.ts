import { restOn, stagedReview } from "./lib/clj";
import { startMeerkat } from "./lib/runner";
import { expect, test } from "./lib/test";

// Clojure hover (docs/features/clojure-hover.md) across the browser to
// LiveView seam: the pointer resting on a symbol finds its line, side and
// column, the server answers, and the popup shows the answer. Which var
// answers, and from which side's text, is covered by ExUnit.

const util = (doc: string, body = "x") => `(ns app.util)

(defn helper
  "${doc}"
  [x]
  ${body})
`;

const core = (body: string) => `(ns app.core
  (:require [app.util :as u]))

(defn run [y]
  ${body})
`;

test("resting on a symbol shows its docs and source for that row's side, and a long source scrolls in a popup the reviewer can resize", async ({
	page,
}) => {
	// `big`'s source is too long for the popup to show at once.
	const long = Array.from({ length: 80 }, (_, i) => `(+ x ${i})`).join("\n  ");
	const big = `\n(defn big\n  "Doc."\n  [x]\n  ${long})\n`;
	const fixture = stagedReview(
		{ "src/app/util.clj": util("Old doc.") + big, "src/app/core.clj": core("(u/helper y)") },
		{
			"src/app/util.clj": util("New doc.") + big,
			"src/app/core.clj": core("(inc (u/helper y) (u/big y))"),
		},
	);
	const meerkat = await startMeerkat({ fixture });
	try {
		await page.goto(meerkat.url);
		const popup = page.locator('[data-test="clj-hover"]');
		// Room below the diff, so the page can scroll.
		await page.evaluate(() => {
			document.body.style.paddingBottom = "100vh";
		});

		const symbol = await restOn(page, "new", "u/helper");
		// The repo's own var opens on its source, highlighted by the
		// diff's own highlighter.
		const sourceTab = popup.getByRole("tab", { name: "src/app/util.clj:3" });
		await expect(sourceTab).toHaveAttribute("aria-selected", "true");
		await expect(popup.locator(".clj-hover-doc")).toHaveCount(0);
		await expect(popup.locator('.clj-hover-source span[style*="--diff-view-"]').first()).toBeAttached();
		await expect(popup.locator(".clj-hover-source")).toContainText('"New doc."');

		// The pointer can move onto the popup and switch to the docs tab.
		// Its new height re-places it, at its symbol though the page has
		// scrolled since it opened. The pointer is on the popup before the
		// scroll: left on the diff, the scroll would rest it on another line,
		// which moves or closes the popup if the click comes later than the
		// hover delay, as on a loaded machine.
		const docsTab = popup.getByRole("tab", { name: "app.util/helper" });
		await docsTab.hover();
		const scrolled = await page.evaluate(() => {
			window.scrollBy(0, 40);
			return window.scrollY;
		});
		expect(scrolled).toBeGreaterThan(0);
		await docsTab.click();
		await expect(popup.locator(".clj-hover-source")).toHaveCount(0);
		await expect(popup.locator(".clj-hover-doc")).toHaveText("New doc.");
		// Below the symbol its top is just under it; above, its bottom just
		// over it. A resize observer re-places it, so this retries.
		await expect
			.poll(async () => {
				const box = await popup.boundingBox();
				if (!box) return Number.POSITIVE_INFINITY;
				return Math.min(
					Math.abs(box.y - (symbol.bottom - scrolled)),
					Math.abs(symbol.top - scrolled - (box.y + box.height)),
				);
			})
			.toBeLessThanOrEqual(5);

		// Resting on the same var on the other side, straight from the
		// popup, moves it there with that side's answer.
		await restOn(page, "old", "u/helper");
		await expect(popup).toContainText('"Old doc."');
		await expect(popup).toHaveCount(1);

		// A symbol nothing answers for closes it.
		await restOn(page, "new", "inc");
		await expect(popup).toHaveCount(0);

		await restOn(page, "new", "u/helper");
		await expect(popup).toBeVisible();

		// Leaving the diff closes it.
		await page.mouse.move(5, 5);
		await expect(popup).toHaveCount(0);

		// In unified view, a long source scrolls within the popup.
		await page.getByRole("button", { name: "Unified", exact: true }).click();
		await expect(page.locator("td.diff-line-content").first()).toBeVisible();

		await restOn(page, "new", "u/big");
		const panel = popup.getByRole("tabpanel");
		const last = panel.getByText("(+ x 79)");
		await expect(last).toBeAttached();
		await expect(last).not.toBeInViewport();

		// Scrolled within the popup, the whole source is there.
		await panel.hover();
		await page.mouse.wheel(0, 5000);
		await expect(last).toBeInViewport();

		// Dragging the bottom-right corner resizes it, past its opening
		// cap, and the popup stays open and in place.
		const before = await popup.boundingBox();
		if (!before) throw new Error("no popup box");
		const corner = { x: before.x + before.width - 3, y: before.y + before.height - 3 };
		await page.mouse.move(corner.x, corner.y);
		await page.mouse.down();
		await page.mouse.move(corner.x + 60, corner.y + 120, { steps: 6 });
		await page.mouse.up();
		const after = await popup.boundingBox();
		expect(after?.x).toBe(before.x);
		expect(after?.y).toBe(before.y);
		expect(after?.height).toBeGreaterThan(before.height + 100);
		expect(after?.width).toBeGreaterThan(before.width + 40);
		await expect(popup).toBeVisible();

		// Off macOS, a Clojure suggestion keeps CodeMirror's bindings and shows
		// no Keys link; suggestion-editor.spec.ts covers macOS. The page reads
		// the platform before its scripts load.
		await page.addInitScript(() => {
			Object.defineProperty(Navigator.prototype, "platform", { get: () => "Linux x86_64" });
		});
		await page.reload();
		const core = page.locator(".file-section").filter({ hasText: "src/app/core.clj" });
		await core.locator('td.diff-line-num span[data-line-new-num="5"]').click();
		const form = core.locator('tr.meerkat-form-row[data-meerkat-form-anchor="5"] .comment-form');
		await form.getByRole("button", { name: /^Suggestion$/ }).click();
		const content = form.locator(".code-host .cm-content");
		await expect.poll(() => content.evaluate((el) => el.textContent)).toBe("  (inc (u/helper y) (u/big y)))");
		await expect(form.getByRole("button", { name: "Keys" })).toHaveCount(0);
		// CodeMirror's Ctrl+Shift+K deletes the line, rather than slurping.
		await form.locator(".code-host .cm-line").click();
		await page.keyboard.press("Control+Shift+K");
		await expect.poll(() => content.evaluate((el) => el.textContent)).toBe("");
	} finally {
		await meerkat.kill();
	}
});

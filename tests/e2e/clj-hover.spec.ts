import { spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Page } from "@playwright/test";
import { makeFixture } from "./lib/fixture";
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

// A staged review of `files` changed from `base`.
function stagedReview(base: Record<string, string>, files: Record<string, string>) {
	const fixture = makeFixture({ files: {} });
	const write = (all: Record<string, string>) => {
		for (const [path, body] of Object.entries(all)) {
			mkdirSync(join(fixture.dir, path, ".."), { recursive: true });
			writeFileSync(join(fixture.dir, path), body);
			fixture.git("add", path);
		}
	};
	write(base);
	fixture.git("commit", "-qm", "base");
	write(files);
	// The user's own clj-kondo run, whose cache names each namespace's file.
	mkdirSync(join(fixture.dir, ".clj-kondo"));
	spawnSync("clj-kondo", ["--lint", "src"], { cwd: fixture.dir });
	return fixture;
}

// Rests the pointer on the first character of `word` in a code cell of
// `side`, the way a reviewer does, and returns that character's box.
async function restOn(page: Page, side: "old" | "new", word: string) {
	// Unified view's rows show a side by the line numbers they carry.
	const cells =
		side === "old"
			? "td.diff-line-old-content, tr:not(:has([data-line-new-num])) > td.diff-line-content"
			: "td.diff-line-new-content, tr:has([data-line-new-num]) > td.diff-line-content";
	const point = await page.evaluate(
		({ cells, word }) => {
			for (const cell of document.querySelectorAll(cells)) {
				const raw = cell.querySelector(".diff-line-syntax-raw, .diff-line-content-raw");
				if (!raw) continue;
				const walker = document.createTreeWalker(raw, NodeFilter.SHOW_TEXT);
				for (let node = walker.nextNode(); node; node = walker.nextNode()) {
					const at = node.textContent?.indexOf(word) ?? -1;
					if (at < 0) continue;
					const range = document.createRange();
					range.setStart(node, at);
					range.setEnd(node, at + 1);
					const r = range.getBoundingClientRect();
					return { x: r.left + r.width / 2, y: r.top + r.height / 2, top: r.top, bottom: r.bottom };
				}
			}
			return null;
		},
		{ cells, word },
	);
	if (!point) throw new Error(`no ${word} on the ${side} side`);
	await page.mouse.move(point.x, point.y);
	return point;
}

test("resting on a symbol shows its docs and source for that row's side", async ({ page }) => {
	const fixture = stagedReview(
		{ "src/app/util.clj": util("Old doc."), "src/app/core.clj": core("(u/helper y)") },
		{ "src/app/util.clj": util("New doc."), "src/app/core.clj": core("(inc (u/helper y))") },
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
		// scrolled since it opened.
		const scrolled = await page.evaluate(() => {
			window.scrollBy(0, 40);
			return window.scrollY;
		});
		expect(scrolled).toBeGreaterThan(0);
		await popup.getByRole("tab", { name: "app.util/helper" }).click();
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
	} finally {
		await meerkat.kill();
	}
});

test("a long source scrolls in a popup the reviewer can resize, in unified view", async ({
	page,
}) => {
	const long = Array.from({ length: 80 }, (_, i) => `(+ x ${i})`).join("\n  ");
	const fixture = stagedReview(
		{ "src/app/util.clj": util("Doc.", long), "src/app/core.clj": core("(u/helper y)") },
		{ "src/app/core.clj": core("(inc (u/helper y))") },
	);
	const meerkat = await startMeerkat({ fixture });
	try {
		await page.goto(meerkat.url);
		await page.getByRole("button", { name: "Unified", exact: true }).click();
		await expect(page.locator("td.diff-line-content").first()).toBeVisible();
		const popup = page.locator('[data-test="clj-hover"]');

		await restOn(page, "new", "u/helper");
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
	} finally {
		await meerkat.kill();
	}
});

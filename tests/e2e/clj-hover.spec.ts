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
	return fixture;
}

// Rests the pointer on the first character of `word` in a code cell of
// `side`, the way a reviewer does.
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
					return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
				}
			}
			return null;
		},
		{ cells, word },
	);
	if (!point) throw new Error(`no ${word} on the ${side} side`);
	await page.mouse.move(point.x, point.y);
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

		await restOn(page, "new", "u/helper");
		await expect(popup).toContainText("app.util/helper");
		await expect(popup).toContainText("New doc.");
		await expect(popup).toContainText("src/app/util.clj:3");
		// Highlighted by the diff's own highlighter.
		await expect(popup.locator('.clj-hover-source span[style*="--diff-view-"]').first()).toBeAttached();

		// Leaving the diff closes it.
		await page.mouse.move(5, 5);
		await expect(popup).toHaveCount(0);

		await restOn(page, "old", "u/helper");
		await expect(popup).toContainText("Old doc.");
	} finally {
		await meerkat.kill();
	}
});

test("a long source is collapsed until expanded, in unified view", async ({ page }) => {
	const long = Array.from({ length: 30 }, (_, i) => `(+ x ${i})`).join("\n  ");
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
		const expand = popup.getByRole("button", { name: "Show all 33 lines" });
		await expect(expand).toBeVisible();
		await expect(popup).not.toContainText("(+ x 29)");

		// The pointer can move onto the popup and use it.
		await expand.click();
		await expect(popup).toContainText("(+ x 29)");
		await expect(expand).toHaveCount(0);
	} finally {
		await meerkat.kill();
	}
});

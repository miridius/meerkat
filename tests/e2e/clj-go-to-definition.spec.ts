import { restOn, stagedReview, symbolPoint } from "./lib/clj";
import { startMeerkat } from "./lib/runner";
import { expect, test } from "./lib/test";

// Clojure go to definition (docs/features/clojure-go-to-definition.md)
// across the browser to LiveView seam: Cmd (Ctrl off macOS) underlines
// a symbol that resolves, a Cmd-click or the hover popup's Go to link
// jumps to the definition, in the diff or a file view. Which symbol
// resolves where is covered by ExUnit.

// Many lines, so the diff folds `helper`'s away from a change at the end.
const util = `(ns app.util)

(defn helper
  "Helps."
  [x]
  x)
${Array.from({ length: 40 }, (_, i) => `\n(defn filler-${i} [] ${i})`).join("\n")}
`;

const other = `(ns app.other
  (:require [clojure.spec.alpha :as s]))

(s/def ::thing string?)

(defn thing
  "Other doc."
  [z]
  z)
`;

const core = (body: string) => `(ns app.core
  (:require [app.util :as u]
            [app.other :as o]))

(defn run [y]
  ${body})
`;

test("Cmd underlines a symbol that resolves, and a Cmd-click or Go to jumps to its definition in the diff, revealing it, or in a file view", async ({
	page,
}) => {
	const fixture = stagedReview(
		{ "src/app/util.clj": util, "src/app/other.clj": other, "src/app/core.clj": core("(u/helper y)") },
		{
			"src/app/util.clj": `${util}\n(defn added [] 1)\n`,
			"src/app/core.clj": core("[(u/helper (o/thing y)) :app.other/thing (u/nope)]"),
		},
	);
	const meerkat = await startMeerkat({ fixture });
	try {
		await page.goto(meerkat.url);
		const util = page.locator(".file-section").filter({ hasText: "src/app/util.clj" });
		const helperRow = util.locator('td.diff-line-new-num span[data-line-num="3"]');
		// Folded away from the diff's one change.
		await expect(helperRow).toHaveCount(0);

		// Cmd (Ctrl off macOS) held over a symbol that resolves underlines it.
		const link = page.locator('[data-test="clj-link"]');
		await page.keyboard.down("ControlOrMeta");
		await restOn(page, "new", "u/helper");
		await expect(link).toBeVisible();
		// Released, the underline goes.
		await page.keyboard.up("ControlOrMeta");
		await expect(link).toHaveCount(0);

		// A plain click selects text and jumps nowhere.
		const plain = await symbolPoint(page, "new", "o/thing");
		await page.mouse.click(plain.x, plain.y);
		await expect(page.locator('[data-test="clj-file-view"]')).toHaveCount(0);

		// A Cmd-click reveals a definition folded context hides.
		await cmdClick(page, "new", "u/helper");
		await expect(helperRow).toBeInViewport();

		// A var outside the diff opens the file view at its line.
		await cmdClick(page, "new", "o/thing");
		const view = page.locator('[data-test="clj-file-view"]');
		await expect(view.locator("header")).toContainText("src/app/other.clj");
		await expect(view.locator('[data-clj-line="6"]')).toBeInViewport();
		await expect(view.locator('[data-clj-line="6"]')).toHaveText("6(defn thing");
		// Highlighted as the diff is.
		await expect(view.locator('[data-clj-line="6"] span[style*="--diff-view-"]').first()).toBeAttached();

		// Hover works in the view, and so does go to definition: the local
		// `z` lands on its binding.
		// The second `thing` is the var's name; the first, the spec's.
		await restOn(page, "view", "thing", 2);
		const popup = page.locator('[data-test="clj-hover"]');
		await expect(popup).toContainText("app.other/thing");
		// `z`'s second appearance is its use.
		await cmdClick(page, "view", "z", 2);
		await expect(view.locator('[data-clj-line="8"]')).toBeInViewport();

		// Esc closes it.
		await page.keyboard.press("Escape");
		await expect(view).toHaveCount(0);

		// A spec keyword opens its s/def.
		await cmdClick(page, "new", ":app.other/thing");
		await expect(view.locator('[data-clj-line="4"]')).toBeInViewport();
		await view.getByRole("button", { name: "Close file view" }).click();
		await expect(view).toHaveCount(0);

		// A symbol nothing defines shows a brief note.
		await cmdClick(page, "new", "u/nope");
		await expect(page.locator('[data-test="clj-no-definition"]')).toHaveText("No definition found");
		await expect(page.locator('[data-test="clj-no-definition"]')).toHaveCount(0);

		// The hover popup's Go to link jumps too, here into a file the
		// reviewer collapsed.
		await util.getByRole("checkbox", { name: "Approved" }).check();
		await expect(helperRow).toHaveCount(0);
		await restOn(page, "new", "u/helper");
		await popup.getByRole("button", { name: "Go to" }).click();
		await expect(helperRow).toBeInViewport();
	} finally {
		await meerkat.kill();
	}
});

// Cmd-clicks (Ctrl off macOS) the `nth` `word` (see `symbolPoint`).
async function cmdClick(page: Parameters<typeof symbolPoint>[0], side: "old" | "new" | "view", word: string, nth = 1) {
	const { x, y } = await symbolPoint(page, side, word, nth);
	await page.keyboard.down("ControlOrMeta");
	await page.mouse.click(x, y);
	await page.keyboard.up("ControlOrMeta");
}

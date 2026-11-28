import { restOn, stagedReview, symbolPoint } from "./lib/clj";
import { startMeerkat } from "./lib/runner";
import { afterNextFrame, expect, test } from "./lib/test";

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

(defn tail [] (missing-fn))
`;

const core = (body: string) => `(ns app.core
  (:require [app.util :as u]
            [app.other :as o]))

(defn run [y]
  ${body})
`;

test("Cmd underlines a symbol that resolves, a Cmd-click or Go to jumps to its definition in the diff, revealing it, or in a file view, and Esc or a click outside steps back", async ({
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
		const history = await page.evaluate(() => window.history.length);
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

		// A Cmd-click reveals a definition folded context hides, closing
		// the hover popup the pointer opened, which would cover it.
		const helper = await restOn(page, "new", "u/helper");
		await expect(page.locator('[data-test="clj-hover"]')).toBeVisible();
		await page.keyboard.down("ControlOrMeta");
		await expect(link).toBeVisible();
		await page.mouse.click(helper.x, helper.y);
		await page.keyboard.up("ControlOrMeta");
		// Closed by the click itself, before the jump scrolls the page.
		expect(await page.locator('[data-test="clj-hover"]').count()).toBe(0);
		await expect(helperRow).toBeInViewport();
		// The jump has landed once the line flashes and the page stops.
		await expect
			.poll(() => helperRow.evaluate((num) => num.closest("tr")?.getAnimations({ subtree: true }).length))
			.toBeGreaterThan(0);
		await expect
			.poll(async () => {
				const before = await page.evaluate(() => window.scrollY);
				await afterNextFrame(page);
				return before > 0 && before === (await page.evaluate(() => window.scrollY));
			})
			.toBe(true);

		// Esc steps back to where the jump started.
		await page.keyboard.press("Escape");
		await expect.poll(async () => (await symbolPoint(page, "new", "u/helper")).y).toBeCloseTo(helper.y, -1);

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

		// Esc closes the popup first, then steps back through the jumps:
		// to the file view the jump to `z` started in, then to the diff.
		await restOn(page, "view", "thing", 2);
		await expect(popup).toBeVisible();
		await page.keyboard.press("Escape");
		await expect(popup).toHaveCount(0);
		await expect(view).toBeVisible();
		await page.keyboard.press("Escape");
		await expect(view).toBeVisible();
		await page.keyboard.press("Escape");
		await expect(view).toHaveCount(0);
		await expect.poll(async () => (await symbolPoint(page, "new", "o/thing")).y).toBeCloseTo(helper.y, -1);

		// A click outside closes it, back past the jumps within it to the
		// diff.
		await cmdClick(page, "new", "o/thing");
		await cmdClick(page, "view", "z", 2);
		await page.mouse.click(4, 4);
		await expect(view).toHaveCount(0);
		await expect.poll(async () => (await symbolPoint(page, "new", "o/thing")).y).toBeCloseTo(helper.y, -1);

		// A spec keyword opens its s/def, in the file the view showed
		// before it closed, flashing the line.
		await cmdClick(page, "new", ":app.other/thing");
		await expect(view.locator('[data-clj-line="4"]')).toBeInViewport();
		await expect.poll(() => view.locator('[data-clj-line="4"]').evaluate((row) => row.getAnimations().length)).toBe(1);

		// A click on a note the view shows, hanging past its edge, keeps it.
		const size = page.viewportSize();
		if (!size) throw new Error("no viewport");
		await page.setViewportSize({ width: size.width, height: 260 });
		await view.locator('[data-clj-line="11"]').evaluate((row) => row.scrollIntoView({ block: "end" }));
		await cmdClick(page, "view", "missing-fn", 1, false);
		const note = await page.locator('[data-test="clj-no-definition"]').boundingBox();
		const edge = await view.boundingBox();
		if (!note || !edge) throw new Error("no note or view");
		expect(note.y + note.height).toBeGreaterThan(edge.y + edge.height + 2);
		await page.mouse.click(note.x + 4, (note.y + note.height + edge.y + edge.height) / 2);
		await expect(view).toBeVisible();
		await page.setViewportSize(size);
		await view.getByRole("button", { name: "Close file view" }).click();
		await expect(view).toHaveCount(0);

		// A symbol nothing defines shows a brief note.
		await cmdClick(page, "new", "u/nope", 1, false);
		await expect(page.locator('[data-test="clj-no-definition"]')).toHaveText("No definition found");
		await expect(page.locator('[data-test="clj-no-definition"]')).toHaveCount(0);

		// The hover popup's Go to link jumps too, here into a file the
		// reviewer collapsed.
		await util.getByRole("checkbox", { name: "Approved" }).check();
		await expect(helperRow).toHaveCount(0);
		await restOn(page, "new", "u/helper");
		await popup.getByRole("button", { name: "Go to" }).click();
		await expect(helperRow).toBeInViewport();
		// It flashes on through the file drawing, which reuses its rows:
		// watched every frame, as a poll can miss the flash's last 600ms.
		const flashed = await page.evaluate(
			() =>
				new Promise<number>((resolve) => {
					let longest = 0;
					const tick = () => {
						const section = [...document.querySelectorAll(".file-section")].find((s) =>
							s.textContent?.includes("src/app/util.clj"),
						);
						const row = section?.querySelector('td.diff-line-new-num span[data-line-num="3"]')?.closest("tr");
						const at = Math.max(0, ...(row?.getAnimations({ subtree: true }) ?? []).map((a) => Number(a.currentTime)));
						// Over 1s, or cut short.
						if (at > 1000 || (longest > 0 && at === 0)) resolve(Math.max(at, longest));
						else {
							longest = Math.max(longest, at);
							requestAnimationFrame(tick);
						}
					};
					tick();
				}),
		);
		expect(flashed).toBeGreaterThan(1000);

		// No jump added a browser history entry.
		expect(await page.evaluate(() => window.history.length)).toBe(history);
	} finally {
		await meerkat.kill();
	}
});

// Cmd-clicks (Ctrl off macOS) the `nth` `word` (see `symbolPoint`) as a
// reviewer does: once a jump before has stopped scrolling the page, Cmd
// held over it until it underlines, when it resolves, then a click.
async function cmdClick(
	page: Parameters<typeof symbolPoint>[0],
	side: "old" | "new" | "view",
	word: string,
	nth = 1,
	resolves = true,
) {
	await expect
		.poll(async () => {
			const before = await symbolPoint(page, side, word, nth);
			await afterNextFrame(page);
			return (await symbolPoint(page, side, word, nth)).y === before.y;
		})
		.toBe(true);
	const { x, y } = await restOn(page, side, word, nth);
	await page.keyboard.down("ControlOrMeta");
	if (resolves) await expect(page.locator('[data-test="clj-link"]')).toBeVisible();
	await page.mouse.click(x, y);
	await page.keyboard.up("ControlOrMeta");
}

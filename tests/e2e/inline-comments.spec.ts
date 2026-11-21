import { writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Locator, Page } from "@playwright/test";
import { makeFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";
import { afterNextFrame, expect, test } from "./lib/test";

// The browser seams of inline comments. DiffViewer uses PointerEvent and
// setPointerCapture for gutter drags, mounts each comment form as its own
// table row and must keep every mounted form's draft, finding type and
// lint-rule flag while others open, close and post, and while the diff
// re-renders. Posted comments are injected as rows at their anchors,
// marking the anchor row, and torn down on Remove; in Split view each side's
// rows keep the other side in line, and with Wrap off beside a long line
// each row keeps its contents in its side's scroll view. The flags the
// browser sends for a posted comment's toggles come from LiveView's markup
// for global comments and from InlineComment.svelte for inline ones, a
// payload LiveViewTest builds itself. Which forms are open, the footer that
// lists them, how the view stores a range and closing an edit form when its
// comment is removed are covered by the LiveView and ReviewServer tests.
//
// An added file (status A) renders unified regardless of the toolbar
// toggle. Unified mode renders a single `td.diff-line-num` cell holding
// spans tagged `data-line-new-num` / `data-line-old-num`. A modified file
// follows the toggle; in split mode the number spans have
// `pointer-events: none`, so the td is the event target.

// Unified mode renders one `data-line-new-num` span per new-side line.
function newLine(fileSection: Locator, n: number): Locator {
	return fileSection.locator(`td.diff-line-num span[data-line-new-num="${n}"]`);
}

// Split mode's old-side gutter cell for line `n`.
function splitOldLine(fileSection: Locator, n: number): Locator {
	return fileSection.locator(`td.diff-line-old-num:has(span[data-line-num="${n}"])`);
}

// Split mode's new-side gutter cell for line `n`.
function splitNewLine(fileSection: Locator, n: number): Locator {
	return fileSection.locator(`td.diff-line-new-num:has(span[data-line-num="${n}"])`);
}

function formAt(fileSection: Locator, endLine: number): Locator {
	return fileSection.locator(`tr.meerkat-form-row[data-meerkat-form-anchor="${endLine}"] .comment-form`);
}

function commentRowAt(fileSection: Locator, endLine: number): Locator {
	return fileSection.locator(`tr.meerkat-comment-row[data-meerkat-anchor-line="${endLine}"]`);
}

// Drag on the gutter from line `from` to line `to`, the way a reviewer
// selects a range.
async function dragLines(page: Page, fileSection: Locator, from: number, to: number) {
	// Centre the range so the sticky footer can't cover either end.
	await newLine(fileSection, to).evaluate((el) => el.scrollIntoView({ block: "center" }));
	const a = await newLine(fileSection, from).boundingBox();
	const b = await newLine(fileSection, to).boundingBox();
	if (!a || !b) throw new Error("gutter lines not found");
	await page.mouse.move(a.x + a.width / 2, a.y + a.height / 2);
	await page.mouse.down();
	await page.mouse.move(b.x + b.width / 2, b.y + b.height / 2, { steps: 5 });
	await page.mouse.up();
}

test("inline forms opened by click and drag keep each other's drafts, post at their own lines, sit apart from an edit form at the same line, and the flags toggled on posted comments are saved", async ({
	page,
}) => {
	const meerkat = await startMeerkat();
	try {
		await page.goto(meerkat.url);
		// `src/main.rs` is an added file, so it renders unified.
		const fileSection = page.locator(".file-section").filter({ hasText: "src/main.rs" });
		// Labelled "Approve" or, once comments exist, with feedback.
		const approve = page.locator("button.approve-btn");

		await newLine(fileSection, 1).click();
		const first = formAt(fileSection, 1);
		await expect(first).toBeVisible();
		for (const name of [/Correct your instructions\/skills/, /Turn this into a lint rule/]) {
			await expect(first.getByRole("checkbox", { name }), "each agent-instruction checkbox defaults off").not.toBeChecked();
		}
		await first.getByRole("checkbox", { name: /Correct your instructions\/skills/ }).check();
		await first.locator("textarea").fill("comment for line 1");

		await dragLines(page, fileSection, 3, 5);
		const second = formAt(fileSection, 5);
		await expect(second).toBeVisible();
		await expect(first.locator("textarea")).toHaveValue("comment for line 1");
		await second.locator("textarea").fill("comment for lines 3-5");

		// Cancelling one form leaves the others and their text.
		await newLine(fileSection, 6).click();
		const third = formAt(fileSection, 6);
		await expect(third).toBeVisible();
		await third.getByRole("button", { name: /^Cancel$/ }).click();
		await expect(third).toBeHidden();
		await expect(first.locator("textarea")).toHaveValue("comment for line 1");
		await expect(second.locator("textarea")).toHaveValue("comment for lines 3-5");

		// A global form posting leaves the inline drafts alone.
		await page.getByRole("button", { name: /^\+ Add global comment$/ }).click();
		const global = page.locator(".global-comments .comment-form");
		await global.locator("textarea").fill("global text");
		await global.getByRole("button", { name: /^Add Global Comment$/ }).click();
		await expect(page.locator(".global-comments .note")).toContainText("global text");
		await expect(first.locator("textarea")).toHaveValue("comment for line 1");

		await first.getByRole("button", { name: /^Add Comment$/ }).click();
		await expect(first).toBeHidden();
		await expect(commentRowAt(fileSection, 1)).toContainText("comment for line 1");
		await expect(commentRowAt(fileSection, 1)).toContainText("L1 (new)");
		await expect(commentRowAt(fileSection, 1), "each comment gets exactly one row").toHaveCount(1);
		await expect(commentRowAt(fileSection, 5)).toHaveCount(0);
		await expect(second.locator("textarea")).toHaveValue("comment for lines 3-5");
		const anchorRow = fileSection.locator('tr.diff-line:has(td.diff-line-num span[data-line-new-num="1"])').first();
		await expect(anchorRow).toHaveClass(/has-inline-comment/);
		const instructions = commentRowAt(fileSection, 1).locator(
			".inline-comment .flag-toggle[data-flag=correct_instructions] input",
		);
		await expect(instructions, "the form's instructions box posts with the comment").toBeChecked();

		// Meta+Enter on macOS / Ctrl+Enter elsewhere: both map to the
		// form's handler because the JS check is (metaKey || ctrlKey).
		await second.locator("textarea").press("Meta+Enter");
		await expect(second, "Cmd+Enter inside the form submits").toBeHidden();
		await expect(commentRowAt(fileSection, 5)).toContainText("comment for lines 3-5");
		await expect(commentRowAt(fileSection, 5)).toContainText("L3–5 (new)");
		await expect(commentRowAt(fileSection, 1)).not.toContainText("comment for lines 3-5");

		// An add form and an edit form at the same line: anchor row, then
		// the comment row, then the add form, then the edit form opened
		// after it.
		await newLine(fileSection, 7).click();
		await formAt(fileSection, 7).locator("textarea").fill("alpha");
		await formAt(fileSection, 7).getByRole("button", { name: /^Add Comment$/ }).click();
		await expect(commentRowAt(fileSection, 7)).toContainText("alpha");

		await newLine(fileSection, 7).click();
		await formAt(fileSection, 7).locator("textarea").fill("gamma");
		await commentRowAt(fileSection, 7).getByRole("button", { name: "Edit" }).click();
		await expect(formAt(fileSection, 7)).toHaveCount(2);

		const comment = 'tr.meerkat-comment-row[data-meerkat-anchor-line="7"]';
		const addForm = fileSection.locator(`${comment} + tr.meerkat-form-row textarea`);
		const editRow = fileSection.locator(`${comment} + tr.meerkat-form-row + tr.meerkat-form-row`);
		await expect(addForm).toHaveValue("gamma");
		await expect(editRow.locator("textarea")).toHaveValue("alpha");

		await editRow.locator("textarea").fill("beta");
		await editRow.getByRole("button", { name: /^Save$/ }).click();
		await expect(formAt(fileSection, 7)).toHaveCount(1);
		await expect(formAt(fileSection, 7).locator("textarea")).toHaveValue("gamma");
		await expect(commentRowAt(fileSection, 7)).toContainText("beta");
		await expect(commentRowAt(fileSection, 7)).not.toContainText("alpha");

		await commentRowAt(fileSection, 1).getByRole("button", { name: /^Remove$/ }).click();
		await expect(commentRowAt(fileSection, 1)).toHaveCount(0);
		await expect(commentRowAt(fileSection, 5)).toContainText("comment for lines 3-5");
		await expect(anchorRow, "the marker clears with its comment").not.toHaveClass(/has-inline-comment/);

		// The unsaved-form gate holds until the last form closes.
		await expect(approve).toBeDisabled();
		await formAt(fileSection, 7).getByRole("button", { name: /^Cancel$/ }).click();
		await expect(page.locator(".comment-form")).toHaveCount(0);
		await expect(approve).toBeEnabled();

		// The flags toggled on posted global and inline comments are saved.
		const globalLint = page.locator(".global-comments .flag-toggle[data-flag=lint_rule] input");
		const toggles = [commentRowAt(fileSection, 5).locator(".inline-comment .flag-toggle[data-flag=lint_rule] input"), globalLint];
		// The socket delivers events in order, so once the server re-renders
		// the global toggle, which is toggled last, it has every toggle.
		const reloadOnceSaved = async (next: string) => {
			await expect(globalLint).toHaveAttribute("phx-value-checked", next);
			await page.reload();
		};
		for (const toggle of toggles) await toggle.check();
		await reloadOnceSaved("false");
		for (const toggle of toggles) await expect(toggle, "a ticked flag survives a reload").toBeChecked();
		for (const toggle of toggles) await toggle.uncheck();
		await reloadOnceSaved("true");
		for (const toggle of toggles) await expect(toggle, "an unticked flag survives a reload").not.toBeChecked();
	} finally {
		await meerkat.kill();
	}
});

const LONG = `${"x".repeat(600)}\n`;

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

test("drags comment on the range dragged over, and forms and comments survive every view toggle and a reload, keep Split view's sides in line, and stay in view beside a long line", async ({
	page,
}) => {
	const long = Array.from({ length: 40 }, (_, i) => `line ${i + 1}`);
	const aligned = Array.from({ length: 30 }, (_, i) => `line ${i + 1}`);
	const fixture = makeFixture({
		files: {
			"src/lib.rs": "fn a() {}\nfn b() {}\nfn c() {}\n",
			"src/long.txt": `${long.join("\n")}\n`,
			"a.txt": `${aligned.join("\n")}\n`,
			"wide.txt": `short\n${LONG}`,
		},
	});
	fixture.git("commit", "-q", "-m", "base");
	writeFileSync(join(fixture.dir, "src/lib.rs"), "fn a() {}\nfn b2() {}\nfn c() {}\nfn d() {}\nfn e() {}\n");
	writeFileSync(join(fixture.dir, "src/added.rs"), "fn one() {}\nfn two() {}\nfn three() {}\n");
	long[29] = "line 30 changed";
	writeFileSync(join(fixture.dir, "src/long.txt"), `${long.join("\n")}\n`);
	aligned[9] = "line 10 changed";
	aligned[19] = "line 20 changed";
	writeFileSync(join(fixture.dir, "a.txt"), `${aligned.join("\n")}\n`);
	writeFileSync(join(fixture.dir, "wide.txt"), `shorter\n${LONG}${LONG}`);
	fixture.git("add", "src/lib.rs", "src/added.rs", "src/long.txt", "a.txt", "wide.txt");

	const meerkat = await startMeerkat({ fixture });
	try {
		await page.goto(meerkat.url);
		const section = (name: string) => page.locator(".file-section").filter({ hasText: name });
		const added = section("src/added.rs");
		const lib = section("src/lib.rs");
		const longFile = section("src/long.txt");
		const wrap = page.getByRole("checkbox", { name: "Wrap" });

		await test.step("a drag shades only the lines and side in its range while it lasts, and comments on the whole range", async () => {
			const shade = "rgba(31, 111, 235, 0.32)";
			// In the added file's unified gutter, the lines in a drag's range
			// are highlighted over the add shading.
			const addedLines = added.locator("td.diff-line-num span[data-line-new-num]");
			await addedLines.nth(0).hover();
			await page.mouse.down();
			await addedLines.nth(2).hover();
			const numCell = added.locator("td.diff-line-num.drag-selecting").first();
			const codeCell = added.locator("tr.drag-selecting > td:not(.diff-line-num)").first();
			await expect(numCell).toHaveCSS("background-color", shade);
			await expect(numCell).toHaveCSS("color", "rgb(255, 255, 255)");
			await expect(codeCell).toHaveCSS("background-color", shade);
			await page.mouse.up();
			await added.locator(".comment-form").getByRole("button", { name: /^Cancel$/ }).click();
			await expect(page.locator(".comment-form")).toHaveCount(0);

			// In the modified file's split gutter, only the dragged side is
			// shaded, and only for as long as a row is in the range.
			await expect(splitNewLine(lib, 1), "the modified file renders split").toBeVisible();
			await splitNewLine(lib, 1).hover();
			await page.mouse.down();
			await splitNewLine(lib, 3).hover();
			const row = lib.locator('tr.diff-line:has(td.diff-line-new-num span[data-line-num="1"])');
			await expect(row.locator("td.diff-line-new-content")).toHaveCSS("background-color", shade);
			await expect(row.locator("td.diff-line-old-num")).not.toHaveCSS("background-color", shade);
			await expect(row.locator("td.diff-line-old-content")).not.toHaveCSS("background-color", shade);
			const lastRow = lib.locator('tr.diff-line:has(td.diff-line-new-num span[data-line-num="3"])');
			await expect(lastRow.locator("td.diff-line-new-content")).toHaveCSS("background-color", shade);
			await splitNewLine(lib, 1).hover();
			await expect(
				lastRow.locator("td.diff-line-new-content"),
				"shrinking the drag unshades the rows it leaves",
			).not.toHaveCSS("background-color", shade);
			await page.mouse.up();
			await expect(row.locator("td.diff-line-new-content"), "releasing the drag unshades its rows").not.toHaveCSS(
				"background-color",
				shade,
			);
			await lib.locator(".comment-form").getByRole("button", { name: /^Cancel$/ }).click();
			await expect(page.locator(".comment-form")).toHaveCount(0);

			await page.getByRole("button", { name: /^Unified$/ }).click();
			await page.getByRole("button", { name: /^Split$/ }).click();
			await expect(added.locator("td.diff-line-new-num"), "the added file stays unified in split mode").toHaveCount(0);

			const commentOnDrag = async (from: Locator, to: Locator, body: string) => {
				await from.dragTo(to);
				const form = page.locator(".comment-form");
				await expect(form).toBeVisible();
				await form.locator("textarea").fill(body);
				await form.getByRole("button", { name: /^Add Comment$/ }).click();
				await expect(form).toBeHidden();
			};
			await commentOnDrag(addedLines.nth(0), addedLines.nth(2), "unified range");
			await expect(added.locator("tr.diff-line.has-inline-comment"), "the unified comment covers lines 1 to 3").toHaveCount(3);
			await commentOnDrag(splitNewLine(lib, 1), splitNewLine(lib, 4), "split range");
			await expect(lib.locator("tr.diff-line.has-inline-comment"), "the split comment covers lines 1 to 4").toHaveCount(4);
		});

		await test.step("open forms and posted comments, including on expanded context lines, survive every view toggle and a reload", async () => {
			// One posted comment, one form with a non-default finding type and
			// lint-rule flag, and a plain draft.
			await splitNewLine(lib, 2).click();
			await formAt(lib, 2).locator("textarea").fill("posted on two");
			await formAt(lib, 2).getByRole("button", { name: /^Add Comment$/ }).click();
			await expect(commentRowAt(lib, 2)).toContainText("posted on two");

			await splitNewLine(lib, 1).click();
			const kept = formAt(lib, 1);
			await kept.getByRole("button", { name: "Question", exact: true }).click();
			await kept.getByRole("checkbox", { name: /Turn this into a lint rule/ }).check();
			await kept.locator("textarea").fill("kept question");

			await splitNewLine(lib, 5).click();
			await expect(formAt(lib, 5)).toBeVisible();
			await formAt(lib, 5).locator("textarea").fill("second draft");

			// In unified mode, expand the context above the change until line 5
			// shows, then open a form on line 5 and post a comment on line 6.
			await page.getByRole("button", { name: "Unified", exact: true }).click();
			await expect(newLine(longFile, 5)).toHaveCount(0);
			while ((await newLine(longFile, 5).count()) === 0 || (await newLine(longFile, 6).count()) === 0) {
				await longFile.locator("td.diff-line-hunk-action button").first().click();
			}
			await newLine(longFile, 6).click();
			await formAt(longFile, 6).locator("textarea").fill("posted on context");
			await formAt(longFile, 6).getByRole("button", { name: /^Add Comment$/ }).click();
			await expect(commentRowAt(longFile, 6)).toContainText("posted on context");
			await newLine(longFile, 5).click();
			await formAt(longFile, 5).locator("textarea").fill("on a context line");

			const expectKept = async () => {
				await expect(kept).toHaveCount(1);
				await expect(kept.locator(".finding-chip.active")).toHaveText("Question");
				await expect(kept.getByRole("checkbox", { name: /Turn this into a lint rule/ })).toBeChecked();
				await expect(kept.locator("textarea")).toHaveValue("kept question");
				await expect(formAt(lib, 5).locator("textarea")).toHaveValue("second draft");
				await expect(commentRowAt(lib, 2)).toContainText("posted on two");
				await expect(formAt(longFile, 5).locator("textarea")).toHaveValue("on a context line");
				await expect(commentRowAt(longFile, 6)).toContainText("posted on context");
			};
			await expectKept();

			for (const toggle of [
				() => wrap.click(),
				() => page.getByRole("button", { name: "Split", exact: true }).click(),
				() => wrap.click(),
				() => page.getByRole("button", { name: "Unified", exact: true }).click(),
			]) {
				await toggle();
				await expectKept();
			}

			await kept.getByRole("button", { name: /^Add Comment$/ }).click();
			await expect(commentRowAt(lib, 1)).toContainText("question L1 (new)");
			await expect(commentRowAt(lib, 1).getByRole("checkbox", { name: /turn this into a lint rule/ })).toBeChecked();
			await expect(commentRowAt(lib, 1)).toContainText("kept question");

			// A reload restores each open form's text and every posted comment.
			await page.reload();
			await expect(formAt(lib, 5).locator("textarea")).toHaveValue("second draft");
			await expect(formAt(longFile, 5).locator("textarea")).toHaveValue("on a context line");
			await expect(commentRowAt(longFile, 6)).toContainText("posted on context");
			await expect(commentRowAt(lib, 1)).toContainText("kept question");
		});

		await test.step("in Split view, comments and forms on either side keep the two sides in line, with Wrap on or off", async () => {
			const file = section("a.txt");
			await page.getByRole("button", { name: "Split", exact: true }).click();
			await expect(splitOldLine(file, 10)).toBeVisible();
			// Each shown line below the rows sits at the same height on both
			// sides.
			const misaligned = () =>
				file.evaluate((section) => {
					const top = (side: string, n: number) =>
						section
							.querySelector(`td.diff-line-${side}-num span[data-line-num="${n}"]`)
							?.closest("tr")
							?.getBoundingClientRect().top;
					const off: number[] = [];
					for (const n of [11, 17, 21, 23]) {
						const [o, w] = [top("old", n), top("new", n)];
						if (o === undefined || w === undefined || Math.abs(o - w) > 1) off.push(n);
					}
					return off;
				});

			// An old-side comment and a new-side form at line 10, and a
			// new-side form alone at line 20.
			await splitOldLine(file, 10).click();
			await formAt(file, 10).locator("textarea").fill("old side");
			await formAt(file, 10).getByRole("button", { name: /^Add Comment$/ }).click();
			await expect(file.locator('tr.meerkat-comment-row[data-meerkat-anchor-side="old"]')).toContainText("old side");
			await splitNewLine(file, 10).click();
			await splitNewLine(file, 20).click();
			await expect(formAt(file, 20)).toBeVisible();

			await expect(wrap).toBeChecked();
			for (const checked of [true, false]) {
				if (!checked) {
					await wrap.click();
					await expect(wrap).not.toBeChecked();
					// The rows are placed again in each side's own table.
					await expect(file.locator("table.new-diff-table tr.meerkat-form-row")).toHaveCount(2);
					await expect(file.locator("table.old-diff-table tr.meerkat-comment-row")).toHaveCount(1);
				}
				await expect.poll(misaligned, `Wrap ${checked ? "on" : "off"}`).toEqual([]);
				// A form that grows keeps the other side in line.
				await formAt(file, 20).getByRole("button", { name: "Suggestion", exact: true }).click();
				await expect(formAt(file, 20).locator(".cm-editor")).toBeVisible();
				await expect.poll(misaligned, `Wrap ${checked ? "on" : "off"}, form grown`).toEqual([]);
				// And one that shrinks back.
				await formAt(file, 20).getByRole("button", { name: "Issue", exact: true }).click();
				await expect(formAt(file, 20).locator(".cm-editor")).toHaveCount(0);
				await expect.poll(misaligned, `Wrap ${checked ? "on" : "off"}, form shrunk`).toEqual([]);
			}

			// With Wrap off, the old side's comment at line 10 comes before
			// the new side's form, each level with its blank on the other side.
			const topOf = async (row: Locator) => (await row.boundingBox())?.y;
			const newMirrors = file.locator("table.new-diff-table tr.meerkat-mirror-row");
			const oldMirrors = file.locator("table.old-diff-table tr.meerkat-mirror-row");
			const comment = file.locator("table.old-diff-table tr.meerkat-comment-row");
			const form10 = file.locator('tr.meerkat-form-row[data-meerkat-form-anchor="10"]');
			await expect(newMirrors).toHaveCount(1);
			await expect(oldMirrors).toHaveCount(2);
			const [commentTop, form10Top, newMirrorTop, oldMirrorTop] = await Promise.all(
				[comment, form10, newMirrors.first(), oldMirrors.first()].map(topOf),
			);
			expect(commentTop).toBeLessThan(form10Top ?? 0);
			expect(Math.abs((commentTop ?? 0) - (newMirrorTop ?? -9))).toBeLessThanOrEqual(1);
			expect(Math.abs((form10Top ?? 0) - (oldMirrorTop ?? -9))).toBeLessThanOrEqual(1);

			// Closing a row removes its blank.
			await formAt(file, 20).getByRole("button", { name: /^Cancel$/ }).click();
			await expect(oldMirrors).toHaveCount(1);
			await expect.poll(misaligned, "Wrap off, form closed").toEqual([]);
		});

		await test.step("with Wrap off, inline forms and comments stay in view beside a long line in Split and Unified views", async () => {
			const file = section("wide.txt");
			await page.setViewportSize({ width: 450, height: 900 });
			// This narrow, the toolbar has moved Split / Unified and Wrap into the ⚙ popover.
			const settings = page.locator(".toolbar-settings > summary");
			const viewControls = page.locator(".toolbar-settings-popover .view-controls");
			const inSettings = async (control: Locator) => {
				await settings.click();
				await control.click();
				await settings.click();
			};
			// Wrap is still off from the step above. Located by CSS, as it
			// is hidden once the popover closes.
			await expect(viewControls.locator(".wrap-toggle input")).not.toBeChecked();

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
				const controls = [form.locator(".btn-submit"), form.locator(".btn-cancel"), ...(await form.locator(".flags label").all())];
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
		});
	} finally {
		await meerkat.kill();
	}
});

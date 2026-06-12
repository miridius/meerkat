import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test } from "./lib/test";
import { startMeerkat } from "./lib/runner";
import { makeFixture } from "./lib/fixture";

// Pointer-event helpers — Playwright's high-level click/drag does
// MouseEvent dispatch, but DiffViewer uses PointerEvent +
// setPointerCapture, so we drive the browser's pointer pipeline
// directly via mouse.move / mouse.down / mouse.up.
//
// `src/main.rs` is added (status A), which DiffViewer forces into
// unified mode regardless of the toolbar toggle (the empty old
// side wastes ~half the viewport on one-sided diffs). Unified
// mode renders a single `td.diff-line-num` cell containing inner
// spans tagged with `data-line-new-num` / `data-line-old-num`.

test.describe("diff line click + drag selection", () => {
	test("clicking a single line opens the comment form anchored at that line", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			const fileSection = page.locator(".file-section").filter({ hasText: "src/main.rs" });
			const firstNewLine = fileSection
				.locator("td.diff-line-num span[data-line-new-num]")
				.first();
			await expect(firstNewLine).toBeVisible();

			await firstNewLine.click();

			await expect(page.locator(".comment-form")).toBeVisible();
		} finally {
			await meerkat.kill();
		}
	});

	test("dragging across two lines opens a multi-line range form", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			const fileSection = page.locator(".file-section").filter({ hasText: "src/main.rs" });
			const lines = fileSection.locator("td.diff-line-num span[data-line-new-num]");
			const startLine = lines.nth(0);
			const endLine = lines.nth(2);

			await startLine.dragTo(endLine);

			await expect(page.locator(".comment-form")).toBeVisible();
		} finally {
			await meerkat.kill();
		}
	});

	// Split-mode number spans have `pointer-events: none` since
	// @git-diff-view 0.1.4 — the td is the event target, a path the
	// unified-mode tests above never exercise.
	test("split-mode gutter drag across a two-sided diff opens a range form", async ({ page }) => {
		const fixture = makeFixture({ files: { "src/lib.rs": "fn a() {}\nfn b() {}\nfn c() {}\n" } });
		fixture.git("commit", "-q", "-m", "base");
		writeFileSync(
			join(fixture.dir, "src/lib.rs"),
			"fn a() {}\nfn b2() {}\nfn c() {}\nfn d() {}\nfn e() {}\n",
		);
		fixture.git("add", "src/lib.rs");

		const meerkat = await startMeerkat({ fixture });
		try {
			await page.goto(meerkat.url);

			const fileSection = page.locator(".file-section").filter({ hasText: "src/lib.rs" });
			const cell = (line: number) =>
				fileSection.locator(`td.diff-line-new-num:has(span[data-line-num="${line}"])`);
			await expect(cell(1)).toBeVisible();

			await cell(1).dragTo(cell(4));

			await expect(page.locator(".comment-form")).toBeVisible();
		} finally {
			await meerkat.kill();
		}
	});

	// Exercises Git.materialise_staged's :renamed clause: old content
	// is read from the OLD path at HEAD, new content from the index.
	test("staged rename renders the old name and both content sides", async ({ page }) => {
		// Mostly-unchanged body so git's rename detection (similarity
		// >= 50%) pairs the old and new paths instead of reporting
		// delete + add.
		const body = Array.from({ length: 9 }, (_, i) => `fn shared_${i}() {}`).join("\n");
		const fixture = makeFixture({
			files: { "src/old_name.rs": `fn original() {}\n${body}\n` },
		});
		fixture.git("commit", "-q", "-m", "base");
		fixture.git("mv", "src/old_name.rs", "src/new_name.rs");
		writeFileSync(join(fixture.dir, "src/new_name.rs"), `fn renamed_fn() {}\n${body}\n`);
		fixture.git("add", "src/new_name.rs");

		const meerkat = await startMeerkat({ fixture });
		try {
			await page.goto(meerkat.url);

			const fileSection = page.locator(".file-section").filter({ hasText: "src/new_name.rs" });
			await expect(fileSection.locator(".rename-from")).toContainText("(was src/old_name.rs)");
			// Old-side content materialised from the old path at HEAD.
			await expect(fileSection).toContainText("fn original() {}");
			await expect(fileSection).toContainText("fn renamed_fn() {}");
			await expect(fileSection.locator(".read-errors, .diff-error")).toHaveCount(0);
		} finally {
			await meerkat.kill();
		}
	});
});

test.describe("diff toolbar mode toggle", () => {
	test("Split toggle has no effect on one-sided diffs; toggle still updates state", async ({
		page,
	}) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			const file = page.locator(".file-section").filter({ hasText: "src/main.rs" });

			// Added file → unified regardless of toggle state.
			await expect(file.locator("td.diff-line-num").first()).toBeVisible();
			await expect(file.locator("td.diff-line-new-num")).toHaveCount(0);

			// Toolbar toggle still flips the LV's diff_mode assign;
			// other files (modified) would respect it. The added-file
			// stays unified because DiffViewer forces it.
			await page.getByRole("button", { name: /^Unified$/ }).click();
			await expect(file.locator("td.diff-line-num").first()).toBeVisible();
			await page.getByRole("button", { name: /^Split$/ }).click();
			await expect(file.locator("td.diff-line-num").first()).toBeVisible();
		} finally {
			await meerkat.kill();
		}
	});
});

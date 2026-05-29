import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test } from "./lib/test";
import { makeFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";

// `meerkat` accepts three classes of review target:
//   `--commit-msg <path>`    staged-diff review with a commit-msg header
//                            (covered by smoke + comments specs)
//   `<REF>`                   single commit (= REF~1...REF)
//   `<A>..<B>` / `<A>...<B>`  arbitrary range
// This file exercises the range entry points end-to-end.

test.describe("range mode", () => {
	test("REF~1..REF reviews the diff of a single committed change", async ({ page }) => {
		// Build a fixture with two commits — initial empty + a real one.
		// Then point meerkat at HEAD (= HEAD~1...HEAD).
		const fixture = makeFixture({ files: {} });
		writeFileSync(
			join(fixture.dir, "added-by-feature.rs"),
			'fn feature() { println!("added by the feature commit"); }\n',
		);
		fixture.git("add", "added-by-feature.rs");
		fixture.git("commit", "-q", "-m", "Add feature module");

		const meerkat = await startMeerkat({
			fixture,
			args: ["HEAD"],
		});
		try {
			await page.goto(meerkat.url);

			// The committed file shows up.
			await expect(page.getByRole("button", { name: /^▾ A added-by-feature\.rs$/ })).toBeVisible();

			// Single-commit review (REF / REF~1...REF) also surfaces the
			// commit's message in the gutter — "Add feature module" is the
			// L1 subject of the commit we just made.
			await expect(
				page.getByRole("button", {
					name: "Comment on commit message line 1",
				}),
			).toBeVisible();
		} finally {
			await meerkat.kill();
		}
	});

	test("two-dot range (A..B) shows the diff between two refs", async ({ page }) => {
		// Two commits: base = HEAD~1, top = HEAD. Range HEAD~1..HEAD
		// should show only the top commit's added file.
		const fixture = makeFixture({ files: {} });
		writeFileSync(join(fixture.dir, "first.txt"), "first commit body\n");
		fixture.git("add", "first.txt");
		fixture.git("commit", "-q", "-m", "First commit");

		writeFileSync(join(fixture.dir, "second.txt"), "second commit body\n");
		fixture.git("add", "second.txt");
		fixture.git("commit", "-q", "-m", "Second commit");

		const meerkat = await startMeerkat({
			fixture,
			args: ["HEAD~1..HEAD"],
		});
		try {
			await page.goto(meerkat.url);

			// Only the second-commit file is in the diff.
			await expect(page.getByRole("button", { name: /^▾ A second\.txt$/ })).toBeVisible();
			await expect(page.getByRole("button", { name: /first\.txt/ })).toHaveCount(0);
		} finally {
			await meerkat.kill();
		}
	});
});

test.describe("--commit-msg specifics", () => {
	test("'#' comment lines in the commit-msg file are stripped before render", async ({ page }) => {
		// git's commit-msg file canonically includes lines starting
		// with `#` that the editor strips on save. Meerkat should do
		// the same so the gutter doesn't render those as content rows.
		const fixture = makeFixture({
			commitMsg: `Subject

Real body line.

# Please enter the commit message for your changes. Lines starting
# with '#' will be ignored, and an empty message aborts the commit.
# On branch main
`,
		});

		const meerkat = await startMeerkat({ fixture });
		try {
			await page.goto(meerkat.url);

			// Subject rendered as L1.
			await expect(
				page.getByRole("button", {
					name: "Comment on commit message line 1",
				}),
			).toBeVisible();
			// The `#` lines are stripped, so they have no gutter row.
			// The commit-msg section should NOT contain "On branch main".
			await expect(page.locator(".commit-message-section")).not.toContainText(
				"On branch main",
			);
		} finally {
			await meerkat.kill();
		}
	});
});

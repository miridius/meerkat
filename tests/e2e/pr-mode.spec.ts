import { expect, test } from "./lib/test";
import { makePrFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";

// `meerkat --pr <N>` calls `gh pr view <N> --json ...` to fetch PR
// metadata, then `git fetch origin +refs/pull/<N>/head:... +refs/heads/
// <base>:...` to bring the diff into local refs. Both pieces are
// stubbed: `gh` via a shell script in a tmp dir prepended to PATH;
// the remote via a real bare git repo with the matching refs (see
// makePrFixture).

test.describe("--pr mode", () => {
	test("renders the diff between PR head and base, with PR metadata in the header", async ({
		page,
	}) => {
		const fixture = makePrFixture({
			prNumber: 123,
			title: "Feature: a wonderful feature",
			body: "This PR adds the wonderful feature, see linked issue.",
		});

		const meerkat = await startMeerkat({
			fixture,
			args: ["--pr", String(fixture.prNumber)],
			pathPrefixes: [fixture.ghStubDir],
		});
		try {
			await page.goto(meerkat.url);

			// The PR-only file (feature.rs) shows up as added in the
			// diff; the base file (base.txt) does NOT.
			await expect(page.getByRole("button", { name: /^▾ A feature\.rs$/ })).toBeVisible();
			await expect(page.getByRole("button", { name: /base\.txt/ })).toHaveCount(0);

			// PR title appears in the page somewhere — the header
			// renders it for context.
			await expect(page.locator("body")).toContainText("Feature: a wonderful feature");
		} finally {
			await meerkat.kill();
		}
	});
});

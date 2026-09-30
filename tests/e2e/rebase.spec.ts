import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { makeFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";
import { expect, test } from "./lib/test";

const BRANCH = "feature/rebased";
const PR_NUMBER = 77;

// Answers like gh: a PR for `gh pr view feature/rebased`, and gh's own
// failure for a bare `gh pr view` while HEAD is detached.
function ghStub(): string {
	const dir = mkdtempSync(join(tmpdir(), "meerkat-e2e-gh-"));
	const pr = JSON.stringify({
		number: PR_NUMBER,
		baseRefName: "main",
		headRefName: BRANCH,
		title: "Rebased feature",
		body: "",
		url: `https://github.com/example/example/pull/${PR_NUMBER}`,
	});
	writeFileSync(
		join(dir, "gh"),
		`#!/bin/sh
if [ "$1 $2 $3" = "pr view ${BRANCH}" ]; then
  echo '${pr}'
  exit 0
fi
echo 'could not determine current branch: failed to run git: not on any branch' >&2
exit 1
`,
	);
	chmodSync(join(dir, "gh"), 0o755);
	return dir;
}

// The fixture's staged files, restaged while an interactive rebase of
// `branch` stands at an `edit` stop: HEAD detached, rebase in progress.
function fixtureMidRebase(branch: string) {
	const fixture = makeFixture();
	fixture.git("switch", "-q", "-c", branch);
	fixture.git("commit", "-q", "-m", "staged work");
	fixture.git("commit", "--allow-empty", "-q", "-m", "later work");
	fixture.git("-c", "sequence.editor=sed -i.bak -e '1s/^pick/edit/'", "rebase", "-q", "-i", "HEAD~2");
	fixture.git("reset", "-q", "--soft", "HEAD~1");
	return fixture;
}

test.describe("committing mid-rebase", () => {
	test("the review names the branch being rebased and its PR, without a gh warning", async ({
		page,
	}) => {
		const gh = ghStub();
		const meerkat = await startMeerkat({ fixture: fixtureMidRebase(BRANCH), pathPrefixes: [gh] });
		try {
			await page.goto(meerkat.url);
			await expect(page.getByRole("link", { name: `PR #${PR_NUMBER}` })).toBeVisible();
			await expect(page.locator(".branch-chip .chip-value").last()).toHaveText(BRANCH);

			await page.getByRole("button", { name: /^Approve$/ }).click();
			const { code, stderr } = await meerkat.awaitExit();
			expect(code).toBe(0);
			expect(stderr).not.toContain("warning");
		} finally {
			await meerkat.kill();
			rmSync(gh, { recursive: true, force: true });
		}
	});

	test("a detached HEAD outside a rebase skips the PR lookup without a warning", async ({ page }) => {
		const gh = ghStub();
		const fixture = makeFixture();
		fixture.git("checkout", "-q", "--detach");
		const meerkat = await startMeerkat({ fixture, pathPrefixes: [gh] });
		try {
			await page.goto(meerkat.url);
			await expect(page.locator(".diff-toolbar")).toBeVisible();
			await expect(page.getByRole("link", { name: /^PR #/ })).toHaveCount(0);

			await page.getByRole("button", { name: /^Approve$/ }).click();
			const { code, stderr } = await meerkat.awaitExit();
			expect(code).toBe(0);
			expect(stderr).not.toContain("warning");
		} finally {
			await meerkat.kill();
			rmSync(gh, { recursive: true, force: true });
		}
	});
});

import { chmodSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { makeFixture, ownedTmpDir } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";
import { expect, test } from "./lib/test";

const BRANCH = "feature/rebased";
const PR_NUMBER = 77;

function prJson(number: number, headRefName: string): string {
	return JSON.stringify({
		number,
		baseRefName: "main",
		headRefName,
		title: `PR ${number}`,
		body: "",
		url: `https://github.com/example/example/pull/${number}`,
	});
}

// Answers like gh: a PR for `gh pr view feature/rebased`, and gh's own
// failure for a bare `gh pr view` while HEAD is detached.
function ghStub(): string {
	const dir = ownedTmpDir("meerkat-e2e-gh");
	writeFileSync(
		join(dir, "gh"),
		`#!/bin/sh
if [ "$1 $2 $3" = "pr view ${BRANCH}" ]; then
  echo '${prJson(PR_NUMBER, BRANCH)}'
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
});

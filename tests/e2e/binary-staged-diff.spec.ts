import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test } from "./lib/test";
import { makeFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";

// The seam is a binary-only staged commit reaching the browser as a
// review rather than an auto-approval. Classifying binaries by
// attributes and by bytes, and mixed text and binary changes, are
// covered by ExUnit.
test("binary-only staged BUILD.bazel opens a truthful review", async ({ page }) => {
	const fixture = makeFixture({ files: {} });
	try {
		const path = join(fixture.dir, "BUILD.bazel");
		writeFileSync(join(fixture.dir, ".gitattributes"), "BUILD.bazel -diff\n");
		fixture.git("add", ".gitattributes");
		writeFileSync(path, "old target\n");
		fixture.git("add", "BUILD.bazel");
		fixture.git("commit", "-qm", "base");
		writeFileSync(path, "new target\n");
		fixture.git("add", "BUILD.bazel");
		expect(fixture.git("diff", "--cached", "--stat")).toContain("Bin");

		// Getting a URL proves a binary-only commit did not autoapprove.
		const meerkat = await startMeerkat({ fixture });
		try {
			await page.goto(meerkat.url);
			await expect(page.getByRole("button", { name: /^▾ M BUILD\.bazel$/ })).toBeVisible();
			await expect(page.locator('[data-test="binary-notice"]')).toContainText("Binary file — content not displayed.");
			await expect(page.locator('[data-test="binary-notice"]')).toContainText("Review its contents outside Meerkat before approving.");
			await expect(page.locator(".diff-content")).toHaveCount(0);
			await expect(page.getByRole("link", { name: "Open full file", exact: true })).toHaveCount(0);
			await expect(page.locator('[data-test="read-errors"], [data-test="render-error"]')).toHaveCount(0);
		} finally {
			await meerkat.kill();
		}
		const { stderr } = await meerkat.awaitExit();
		expect(stderr).not.toContain("couldn't parse staged-diff block");
		expect(stderr).not.toContain("auto-approving");
	} finally {
		fixture.cleanup();
	}
});

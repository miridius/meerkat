import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test } from "./lib/test";
import { makeFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";

for (const classification of ["attributes", "bytes"] as const) {
	test(`binary-only staged BUILD.bazel (${classification}) opens a truthful review`, async ({ page }) => {
		const fixture = makeFixture({ files: {} });
		try {
			const path = join(fixture.dir, "BUILD.bazel");
			if (classification === "attributes") {
				writeFileSync(join(fixture.dir, ".gitattributes"), "BUILD.bazel -diff\n");
				fixture.git("add", ".gitattributes");
			}
			writeFileSync(path, classification === "bytes" ? Buffer.from([0, 255, 1]) : "old target\n");
			fixture.git("add", "BUILD.bazel");
			fixture.git("commit", "-qm", "base");
			writeFileSync(path, classification === "bytes" ? Buffer.from([0, 254, 2]) : "new target\n");
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
}

test("mixed staged text and binary additions, deletions and renames stay reviewable", async ({ page }) => {
	const fixture = makeFixture({ files: {
		".gitattributes": "*.bin -diff\n*.md -diff\ngenerated.bin linguist-generated=true\n",
		"gone.bin": "old deleted content\n",
		"old.bin": "renamed content\n",
		"query.clj": "(old-query)\n",
	} });
	try {
		fixture.git("commit", "-qm", "base");
		fixture.git("rm", "gone.bin");
		fixture.git("mv", "old.bin", "new.bin");
		writeFileSync(join(fixture.dir, "query.clj"), "(new-query)\n");
		writeFileSync(join(fixture.dir, "added.md"), "# Binary by attributes\n");
		writeFileSync(join(fixture.dir, "generated.bin"), "generated binary content\n");
		fixture.git("add", "query.clj", "added.md", "generated.bin");
		const meerkat = await startMeerkat({ fixture });
		try {
			await page.goto(meerkat.url);
			for (const name of ["gone.bin", "new.bin", "added.md"]) {
				const section = page.locator(".file-section").filter({ has: page.locator(".file-name", { hasText: name }) });
				await expect(section.locator('[data-test="binary-notice"]')).toBeVisible();
				await expect(section.locator(".diff-content, .md-view-toggle")).toHaveCount(0);
			}
			await expect(page.locator(".rename-from")).toContainText("old.bin");
			await expect(page.locator(".diff-content")).toContainText("new-query");
			await page.getByRole("button", { name: "Toggle file list", exact: true }).click();
			await page.locator(".file-filter .filter-chip", { hasText: "generated" }).click();
			const generated = page.locator(".file-section").filter({ has: page.locator(".file-name", { hasText: "generated.bin" }) });
			await expect(generated.locator('[data-test="binary-notice"]')).toBeVisible();
		} finally {
			await meerkat.kill();
		}
		const { stderr } = await meerkat.awaitExit();
		expect(stderr).not.toContain("couldn't parse staged-diff block");
	} finally {
		fixture.cleanup();
	}
});

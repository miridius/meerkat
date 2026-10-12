import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { makeFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";
import { expect, test } from "./lib/test";

// A Clojure file comfortably over @git-diff-view's default 2000-line
// syntax cap. The DiffViewer raises that cap (MAX_SYNTAX_LINES); before
// the fix, files this long rendered with no highlighting at all while
// their shorter siblings were colourful. Clojure also exercises the
// linguist-backed `languageFor` resolution (`.clj` → `clojure`).
function bigCljFile(lines: number): string {
	let out = "(ns big.core)\n\n";
	for (let i = 0; out.split("\n").length < lines; i++) {
		out += `(defn fn-${i} [x] (+ x ${i}))\n`;
	}
	return out;
}

// What the DiffViewer renders in the browser for files that are not
// plain text diffs. Classifying binaries by attributes and by bytes, a
// binary-only staged commit opening a review rather than auto-approving,
// and the props each file reaches the browser with are covered by
// ExUnit.
test("a binary file, a deleted diagram and a long file each render as their kind", async ({
	page,
}) => {
	const fixture = makeFixture({ files: {} });
	try {
		const bazel = join(fixture.dir, "BUILD.bazel");
		writeFileSync(join(fixture.dir, ".gitattributes"), "BUILD.bazel -diff\n");
		writeFileSync(bazel, "old target\n");
		writeFileSync(join(fixture.dir, "flow.puml"), "@startuml\nAlice -> Bob : hi\n@enduml\n");
		fixture.git("add", ".gitattributes", "BUILD.bazel", "flow.puml");
		fixture.git("commit", "-qm", "base");
		writeFileSync(bazel, "new target\n");
		fixture.git("add", "BUILD.bazel");
		fixture.git("rm", "-q", "flow.puml");
		const big = join(fixture.dir, "src", "big.clj");
		mkdirSync(join(fixture.dir, "src"));
		writeFileSync(big, bigCljFile(2500));
		fixture.git("add", big);
		expect(fixture.git("diff", "--cached", "--stat", "BUILD.bazel")).toContain("Bin");

		const meerkat = await startMeerkat({ fixture });
		try {
			await page.goto(meerkat.url);
			const section = (name: string) => page.locator(".file-section").filter({ hasText: name });

			// A binary file says so instead of showing a diff.
			await expect(page.getByRole("button", { name: /^▾ M BUILD\.bazel$/ })).toBeVisible();
			const binary = section("BUILD.bazel");
			const notice = binary.locator('[data-test="binary-notice"]');
			await expect(notice).toContainText("Binary file — content not displayed.");
			await expect(notice).toContainText("Review its contents outside Meerkat before approving.");
			await expect(binary.locator(".diff-content")).toHaveCount(0);
			await expect(binary.getByRole("link", { name: "Open full file", exact: true })).toHaveCount(0);

			// A deleted diagram previews its old side only.
			await expect(page.getByRole("button", { name: /^▾ D flow\.puml$/ })).toBeVisible();
			const preview = page.getByRole("region", { name: "PlantUML preview" });
			await expect(preview.getByText("Old", { exact: true })).toBeVisible();
			await expect(preview.getByText("New", { exact: true })).toHaveCount(0);
			const img = preview.getByRole("img", { name: "PlantUML diagram (Old side)" });
			await expect
				.poll(() => img.evaluate((el: HTMLImageElement) => el.naturalWidth))
				.toBeGreaterThan(0);

			// A file over the library's default syntax cap is still
			// highlighted. Engine-agnostic probe: shiki tokens carry
			// `--diff-view-dark:#…` / `--diff-view-light:#…` colour variables
			// in their style attribute, the lowlight fallback emits `hljs-*`
			// classes. Either counts; zero of both is the bug.
			await expect(page.getByRole("button", { name: /^▾ A src\/big\.clj$/ })).toBeVisible();
			const tokens = section("src/big.clj").locator(
				[
					'.diff-line-syntax-raw span[style*="--diff-view-"]',
					'.diff-line-syntax-raw [class*="hljs-"]',
				].join(", "),
			);
			await expect(tokens.first()).toBeVisible();

			await expect(page.locator('[data-test="read-errors"], [data-test="render-error"]')).toHaveCount(0);
		} finally {
			await meerkat.kill();
		}
		const { stderr } = await meerkat.awaitExit();
		expect(stderr).not.toContain("couldn't parse staged-diff block");
	} finally {
		fixture.cleanup();
	}
});

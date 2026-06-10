import { expect, test } from "./lib/test";
import { makeFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";

// A Clojure file comfortably over @git-diff-view's default
// 2000-line syntax cap. The DiffViewer raises that cap
// (MAX_SYNTAX_LINES) — before the fix, files this long rendered
// with no highlighting at all while their shorter siblings were
// colourful. (Shiki resolves the `.clj` extension by itself via
// its `clj` alias, so this spec needs no language-id mapping.)
function bigCljFile(lines: number): string {
	let out = "(ns big.core)\n\n";
	for (let i = 0; out.split("\n").length < lines; i++) {
		out += `(defn fn-${i} [x] (+ x ${i}))\n`;
	}
	return out;
}

test.describe("syntax highlighting", () => {
	test("highlights a file longer than the library's 2000-line default cap", async ({ page }) => {
		const fixture = makeFixture({ files: { "src/big.clj": bigCljFile(2500) } });
		const meerkat = await startMeerkat({ fixture });
		try {
			await page.goto(meerkat.url);
			await expect(page.getByRole("button", { name: /^▾ A src\/big\.clj$/ })).toBeVisible();

			// Engine-agnostic "is highlighted" probe: shiki tokens carry
			// `--diff-view-dark:#…` / `--diff-view-light:#…` colour
			// variables in their style attribute, the lowlight fallback
			// emits `hljs-*` classes. Either counts; zero of both is the
			// bug. Scoping to `.diff-line-syntax-raw` keeps UI chrome
			// from satisfying the probe.
			const tokens = page.locator(
				[
					'.diff-line-syntax-raw span[style*="--diff-view-"]',
					'.diff-line-syntax-raw [class*="hljs-"]',
				].join(", "),
			);
			await expect(tokens.first()).toBeVisible();
		} finally {
			await meerkat.kill();
		}
	});
});

import { describe, expect, test } from "bun:test";
import { EditorState } from "@codemirror/state";
import { classHighlighter, highlightTree } from "@lezer/highlight";
import { getLoadedLanguage, preloadLanguages, SUPPORTED_LANGUAGES } from "./cmLang";

async function highlightClasses(id: string, src: string): Promise<string[]> {
	await preloadLanguages([id]);
	const support = getLoadedLanguage(id);
	if (!support) throw new Error(`${id} did not load`);
	const classes: string[] = [];
	highlightTree(support.language.parser.parse(src), classHighlighter, (_from, _to, cls) =>
		classes.push(cls),
	);
	return classes;
}

// A language pack whose parser links a different @lezer/common copy than
// @lezer/highlight reads node props by another copy's ids, so the
// highlighter throws and the editor shows no colours at all.
describe("language packs", () => {
	test.each([...SUPPORTED_LANGUAGES])("%s highlights without throwing", async (id) => {
		await highlightClasses(id, '(defn f "doc" [a] {:k nil}) // x\nfn main() { let s = "s"; 1 }');
	});

	test("clojure colours keywords, strings and numbers in part of a form", async () => {
		const classes = (
			await highlightClasses("clojure", '      rate (- (* subtotal rate))\n  (str "s" 1)))')
		).join(" ");
		expect(classes).toContain("tok-keyword");
		expect(classes).toContain("tok-string");
		expect(classes).toContain("tok-number");
	});

	test("clojure leaves bracket pairing but for quotes to paredit, and `'` unpaired", async () => {
		await preloadLanguages(["clojure"]);
		const state = EditorState.create({ doc: "(a)", extensions: getLoadedLanguage("clojure") });
		expect(state.languageDataAt("closeBrackets", 1)).toEqual([{ brackets: ['"'] }]);
	});
});

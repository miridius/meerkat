import { describe, expect, test } from "bun:test";
import { indentSelection, insertNewlineAndIndent } from "@codemirror/commands";
import { javascript } from "@codemirror/lang-javascript";
import { LanguageSupport } from "@codemirror/language";
import { Compartment, EditorSelection, EditorState, type Extension, type Transaction } from "@codemirror/state";
import { clojureLanguage } from "@nextjournal/lang-clojure";
import { clojureIndent } from "./clojureIndent";
import { indentation, openForm, textAbove } from "./cmIndent";

describe("textAbove", () => {
	test("holds the lines above the anchor, so the anchor's lines join it back into the file", () => {
		const source = "one\ntwo\nthree\n";
		expect(textAbove(source, 2)).toBe("one\n");
		expect(`${textAbove(source, 2)}two\nthree\n`).toBe(source);
	});

	test("is empty above the first line", () => {
		expect(textAbove("a\nb", 1)).toBe("");
	});
});

describe("openForm", () => {
	test("is the top-level form still open at the end", () => {
		expect(openForm("(a)\n(defn f [x]\n  (let [y 1]\n", clojureLanguage)).toBe("(defn f [x]\n  (let [y 1]\n");
		expect(openForm("(a)\n^:private (defn f [x]\n", clojureLanguage)).toBe("^:private (defn f [x]\n");
		expect(openForm('(a)\n(defn f\n  "doc\n', clojureLanguage)).toBe('(defn f\n  "doc\n');
	});

	test("is empty when every form above is closed", () => {
		expect(openForm("(a)\n(b)\n", clojureLanguage)).toBe("");
		expect(openForm("(a)\n; (b\n", clojureLanguage)).toBe("");
		expect(openForm("", clojureLanguage)).toBe("");
	});
});

const clojure = new LanguageSupport(clojureLanguage, clojureIndent);

/** Press Enter at the end of line `line` of an editor in `language`
 *  holding lines `start..end` of `file`, and return the new line. */
function enterIn(
	file: string,
	start: number,
	end: number,
	line: number,
	language: string,
	support: Extension,
	withAbove = true,
): string {
	const above = withAbove ? textAbove(file, start) : undefined;
	const doc = file
		.split("\n")
		.slice(start - 1, end)
		.join("\n");
	const compartment = new Compartment();
	let state = EditorState.create({
		doc,
		extensions: [compartment.of(support), indentation(language, above, compartment)],
	});
	state = state.update({ selection: EditorSelection.cursor(state.doc.line(line).to) }).state;
	let tr: Transaction | null = null;
	insertNewlineAndIndent({ state, dispatch: (t) => (tr = t) });
	if (!tr) throw new Error("Enter did nothing");
	return (tr as Transaction).state.doc.line(line + 1).text;
}

const CLJ = `(ns demo.core)

(defn handler [req]
  (let [x (:x req)
        y 2]
    (when (pos? x)
      (println "x" x
               y))))
`;

const JS = `function f(a) {
    if (a) {
        const b = 1;
        return b;
    }
}
`;

describe("Enter", () => {
	test("in Clojure, indents as inside the form in the file", () => {
		// After the binding vector the editor's lines close, the let's
		// body: its opener sits above them.
		expect(enterIn(CLJ, 5, 6, 1, "clojure", clojure)).toBe("    ");
		expect(enterIn(CLJ, 6, 7, 1, "clojure", clojure)).toBe("      ");
		expect(enterIn(CLJ, 6, 7, 2, "clojure", clojure)).toBe("               ");
	});

	test("in Clojure, indents the same below other forms", () => {
		expect(enterIn(`${"(a)\n".repeat(80)}${CLJ}`, 85, 86, 1, "clojure", clojure)).toBe("    ");
	});

	test("in Clojure without the file, indents by the editor's lines alone", () => {
		expect(enterIn(CLJ, 6, 7, 2, "clojure", clojure, false)).toBe("               ");
	});

	test("in Clojure, indents by the text as it is after an edit", () => {
		const compartment = new Compartment();
		let state = EditorState.create({
			doc: CLJ.split("\n").slice(5, 7).join("\n"),
			extensions: [compartment.of(clojure), indentation("clojure", textAbove(CLJ, 6), compartment)],
		});
		const enter = () => {
			insertNewlineAndIndent({ state, dispatch: (t) => (state = t.state) });
		};
		state = state.update({ selection: EditorSelection.cursor(state.doc.length) }).state;
		enter();
		state = state.update(state.replaceSelection("(foo bar")).state;
		enter();
		expect(state.doc.line(4).text).toBe(" ".repeat(20));
	});

	test("in Clojure, re-indents selected lines as inside the form in the file", () => {
		const compartment = new Compartment();
		let state = EditorState.create({
			doc: '(when (pos? x)\n(println "x" x\ny)',
			extensions: [compartment.of(clojure), indentation("clojure", textAbove(CLJ, 6), compartment)],
		});
		state = state.update({ selection: EditorSelection.range(0, state.doc.length) }).state;
		indentSelection({ state, dispatch: (t) => (state = t.state) });
		// Each line after the first indents by the first's new indentation.
		expect(state.doc.toString()).toBe('    (when (pos? x)\n      (println "x" x\n               y)');
	});

	test("in Clojure, keeps the line's indentation until the pack loads", () => {
		expect(enterIn(CLJ, 6, 7, 2, "clojure", [])).toBe("      ");
	});

	test("in other languages, keeps the line's indentation", () => {
		// JavaScript's own rules would indent the `if` body one level more.
		expect(enterIn(JS, 2, 3, 1, "javascript", javascript())).toBe("    ");
		expect(enterIn(JS, 3, 4, 1, "javascript", javascript())).toBe("        ");
	});
});

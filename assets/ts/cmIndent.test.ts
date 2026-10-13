import { describe, expect, test } from "bun:test";
import { insertNewlineAndIndent } from "@codemirror/commands";
import { javascript } from "@codemirror/lang-javascript";
import { go } from "@codemirror/lang-go";
import { python } from "@codemirror/lang-python";
import { indentOnInput, indentUnit, LanguageSupport } from "@codemirror/language";
import { Compartment, EditorSelection, EditorState, type Extension, type Transaction } from "@codemirror/state";
import { clojureLanguage } from "@nextjournal/lang-clojure";
import { clojureIndent } from "./clojureIndent";
import { anchorContext, contextIndentation, detectIndentUnit } from "./cmIndent";

describe("anchorContext", () => {
	const source = "one\ntwo\nthree\nfour\n";

	test("holds the lines around the anchor, so they join its lines back into the file", () => {
		const context = anchorContext(source, 2, 3);
		expect(context).toEqual({ before: "one\n", after: "\nfour\n" });
		expect(`${context.before}two\nthree${context.after}`).toBe(source);
	});

	test("is empty before the first line and after the last", () => {
		expect(anchorContext("a\nb", 1, 2)).toEqual({ before: "", after: "" });
	});
});

describe("detectIndentUnit", () => {
	test("finds four spaces", () => {
		expect(detectIndentUnit("class A:\n    def f(self):\n        return 1\n")).toBe("    ");
	});

	test("finds a tab", () => {
		expect(detectIndentUnit("func f() {\n\tif a {\n\t\tb()\n\t}\n}\n")).toBe("\t");
	});

	test("ignores one-column alignment steps, as in Clojure", () => {
		expect(detectIndentUnit("(defn f [a]\n  (foo a\n   b)\n  (let [x 1]\n    x))")).toBe("  ");
	});

	test("prefers the smaller step on a tie", () => {
		expect(detectIndentUnit("a\n    b\nc\n  d")).toBe("  ");
	});

	test("finds none in flat text", () => {
		expect(detectIndentUnit("a\nb\n")).toBeNull();
	});
});

/** Press Enter at the end of line `line` of an editor holding lines
 *  `start..end` of `file`, and return the new line. */
function enterIn(file: string, start: number, end: number, line: number, support: Extension): string {
	const context = anchorContext(file, start, end);
	const doc = file.split("\n").slice(start - 1, end).join("\n");
	const language = new Compartment();
	const unit = detectIndentUnit(file);
	let state = EditorState.create({
		doc,
		extensions: [language.of(support), contextIndentation(context, language), unit ? indentUnit.of(unit) : []],
	});
	state = state.update({ selection: EditorSelection.cursor(state.doc.line(line).to) }).state;
	let tr: Transaction | null = null;
	insertNewlineAndIndent({ state, dispatch: (t) => (tr = t) });
	if (!tr) throw new Error("Enter did nothing");
	return (tr as Transaction).state.doc.line(line + 1).text;
}

const PY = `class A:
    def f(self, x):
        if x:
            y = x + 1
            return y
        return 0
`;
const GO = "package main\n\nfunc f(a bool) int {\n\tif a {\n\t\tb := 1\n\t\treturn b\n\t}\n\treturn 0\n}\n";
const JS = `function f(a) {
    if (a) {
        const b = 1;
        return b;
    }
    return 0;
}
`;
const CLJ = `(ns demo.core)

(defn handler [req]
  (let [x (:x req)
        y 2]
    (when (pos? x)
      (println "x" x
               y))))
`;

describe("Enter in lines cut from a file", () => {
	test("Python indents as inside the function", () => {
		expect(enterIn(PY, 4, 5, 1, python())).toBe("            ");
		expect(enterIn(PY, 3, 4, 1, python())).toBe("            ");
	});

	test("Go indents with the file's tabs", () => {
		expect(enterIn(GO, 5, 6, 1, go())).toBe("\t\t");
		expect(enterIn(GO, 4, 5, 1, go())).toBe("\t\t");
	});

	test("JavaScript indents as inside the block", () => {
		expect(enterIn(JS, 3, 4, 1, javascript())).toBe("        ");
		expect(enterIn(JS, 2, 3, 1, javascript())).toBe("        ");
	});

	test("Clojure indents as inside the form", () => {
		const clojure = new LanguageSupport(clojureLanguage, clojureIndent);
		// After the binding vector the editor's lines close, the let's
		// body: its opener sits above them.
		expect(enterIn(CLJ, 5, 6, 1, clojure)).toBe("    ");
		expect(enterIn(CLJ, 6, 7, 1, clojure)).toBe("      ");
		expect(enterIn(CLJ, 6, 7, 2, clojure)).toBe("               ");
	});

	test("a file with CRLF line ends indents as one with LF", () => {
		// Each `\r` before the editor's lines would shift positions by one.
		const crlf = `${"a();\n".repeat(80)}${JS}`.replaceAll("\n", "\r\n");
		expect(enterIn(crlf, 82, 83, 1, javascript())).toBe("        ");
	});

	test("without a language, keeps the line's indentation", () => {
		expect(enterIn(PY, 4, 5, 1, [])).toBe("            ");
	});
});

test("typing a closer re-indents its line as in the file", () => {
	const context = anchorContext(JS, 3, 4);
	const language = new Compartment();
	let state = EditorState.create({
		doc: "        const b = 1;\n        return b;\n        ",
		extensions: [language.of(javascript()), contextIndentation(context, language), indentUnit.of("    "), indentOnInput()],
	});
	state = state.update({
		changes: { from: state.doc.length, insert: "}" },
		selection: EditorSelection.cursor(state.doc.length + 1),
		userEvent: "input.type",
	}).state;
	expect(state.doc.line(3).text).toBe("    }");
});

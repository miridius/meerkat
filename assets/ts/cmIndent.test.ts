import { describe, expect, test } from "bun:test";
import { insertNewlineAndIndent } from "@codemirror/commands";
import { javascript } from "@codemirror/lang-javascript";
import { LanguageSupport } from "@codemirror/language";
import { Compartment, EditorSelection, EditorState, type Extension, type Transaction } from "@codemirror/state";
import { clojureLanguage } from "@nextjournal/lang-clojure";
import { clojureIndent } from "./clojureIndent";
import { anchorContext, indentation } from "./cmIndent";

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
	withContext = true,
): string {
	const context = withContext ? anchorContext(file, start, end) : undefined;
	const doc = file.split(/\r?\n/).slice(start - 1, end).join("\n");
	const compartment = new Compartment();
	let state = EditorState.create({
		doc,
		extensions: [compartment.of(support), indentation(language, context, compartment)],
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

	test("in Clojure, a file with CRLF line ends indents as one with LF", () => {
		// Each `\r` before the editor's lines would shift positions by one.
		const crlf = `${"(a)\n".repeat(80)}${CLJ}`.replaceAll("\n", "\r\n");
		expect(enterIn(crlf, 85, 86, 1, "clojure", clojure)).toBe("    ");
	});

	test("in Clojure without the file, indents by the editor's lines alone", () => {
		expect(enterIn(CLJ, 6, 7, 2, "clojure", clojure, false)).toBe("               ");
	});

	test("in other languages, keeps the line's indentation", () => {
		// JavaScript's own rules would indent the `if` body one level more.
		expect(enterIn(JS, 2, 3, 1, "javascript", javascript())).toBe("    ");
		expect(enterIn(JS, 3, 4, 1, "javascript", javascript())).toBe("        ");
	});
});

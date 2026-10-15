import { describe, expect, test } from "bun:test";
import { insertNewlineAndIndent } from "@codemirror/commands";
import { ensureSyntaxTree, getIndentation, LanguageSupport } from "@codemirror/language";
import { EditorSelection, EditorState, type Transaction } from "@codemirror/state";
import { clojureLanguage } from "@nextjournal/lang-clojure";
import { clojureIndent } from "./clojureIndent";

const clojure = new LanguageSupport(clojureLanguage, clojureIndent);

function stateOf(doc: string, selection?: number): EditorState {
	const state = EditorState.create({
		doc,
		selection: selection === undefined ? undefined : EditorSelection.cursor(selection),
		extensions: [clojure],
	});
	ensureSyntaxTree(state, doc.length, 5000);
	// A fresh state's tree stops at its first time budget; an update takes
	// the finished parse.
	return state.update({}).state;
}

// cljfmt's own expected outputs (cljfmt/test/cljfmt/core_test.cljc,
// default options): every code line after the first is indented as
// cljfmt left it.
const CLJFMT_CASES: [string, string[]][] = [
	["list, args on the first line", ["(foo bar", "     baz", "     quz)"]],
	["list, no args on the first line", ["(foo", " bar", " baz)"]],
	["if block", ["(if (= x 1)", "  :foo", "  :bar)"]],
	["do block", ["(do", "  (foo)", "  (bar))"]],
	["do block to hanging argument", ["(do (foo)", "    (bar))"]],
	["deftype fields to class name", ["(deftype Foo", "         [x]", "  Bar)"]],
	["cond->> block", ["(cond->> x", "  a? a", "  b? b)"]],
	["def", ["(def foo", '  "Hello World")']],
	["defn does not indent to hanging name and params", ["(defn foo [x]", "  (+ x 1))"]],
	["defn does not indent to hanging name", ["(defn foo", "  [x]", "  (+ x 1))"]],
	[
		"defn multi-arity",
		["(defn foo", "  ([] 0)", "  ([x]", "   (+ x 1))", "  (^Number [x y]", "   (+ x y)))"],
	],
	["fn with body", ["(fn [x]", "  (foo bar", "       baz))"]],
	["fn with hanging body", ["(fn [x] (foo bar", "             baz))"]],
	["unhangs hanging spec indentation", ["(clojure.spec.alpha/def ::foo", "  string?)"]],
	[
		"unhangs hanging spec indentations",
		["(clojure.spec.alpha/fdef foo", "  :args (clojure.spec.alpha/cat :x string?)", "  :ret nat-int?)"],
	],
	["letfn inner", ["(letfn [(foo [x]", "          (* x x))]", "  (foo 5))"]],
	[
		"letfn two bindings",
		["(letfn [(foo [x]", "          (* x x))", "        (bar [x]", "          (+ x x))]", "  (foo 5))"],
	],
	["reify", ["(reify Closeable", "  (close [_]", "    (prn :closed)))"]],
	["defrecord", ["(defrecord Foo [x]", "  Closeable", "  (close [_]", "    (prn x)))"]],
	["defprotocol with metadata", ["(defprotocol Testing", "  (^:example", "   test-method [x]))"]],
	["vector", ["[:foo", " :bar", " :baz]"]],
	["map", ["{:foo 1", " :bar 2}"]],
	["set", ["#{:foo", "  :bar", "  :baz}"]],
	["vector in map", ["{:foo [:bar", "       :baz]}"]],
	["map in let", ["(let [foo {:x 1", "           :y 2}]", "  (:x foo))"]],
	["do in if", ["(if foo", "  (do bar", "      baz)", "  quz)"]],
	["namespaced defn", ["(t/defn foo [x]", "  (+ x 1))"]],
	["namespaced defrecord", ["(t/defrecord Foo [x]", "  Closeable", "  (close [_]", "    (prn x)))"]],
	["-> in an ns named def", ["(ns def)", "(-> 1", "    prn)"]],
	["anonymous function", ["#(while true", "   (println :foo))"]],
	["anonymous class", ["#(reify Closeable", "   (close [_]", "     (prn %)))"]],
	["fn with one arity", ["(fn", "  ([x]", "   (foo)", "   (bar)))"]],
	["comment after ns", ["(ns foo.core)", "", ";; foo", "(defn foo [x]", "  (inc x))"]],
	["ns require", [";; foo", "(ns foo", "  (:require bar))"]],
	["commented-out line", ["(defn foo [x]", "  ;; +1", "  (inc x))"]],
	["inline comment in let", ["(let [;foo", "      x (foo bar", "             baz)]", "  x)"]],
	["binding inline comment", ["(binding [x 1] ; foo", "  x)"]],
	["closer after a comment", ["(foo a ; b", "     c ; d", "     )"]],
	["closer after comments in do", ["(do", "  a ; b", "  c ; d", "  )"]],
	["closer in a vector after a comment", ["(let [x [1 2 ;; test1", "         2 3 ;; test2", "         ]])"]],
	["hanging metadata on defonce", ['(defonce ^{:doc "foo"}', "  foo", "  :foo)"]],
	["hanging metadata on def", ["(def ^:private", "  foo", "  :foo)"]],
	["hanging metadata and name on def", ["(def ^:private foo", "  :foo)"]],
	["metadata on the head", ["(^:amazing fn [x y]", "  (+ x y))"]],
	["map metadata on the head", ["(^{:amazing true} fn [x y]", "  (+ x y))"]],
	["^with- fuzzy rule", ["(with-foo x", "  y", "  z)"]],
	["^def fuzzy rule", ["(defelem foo [x]", "  [:foo x])"]],
	["not default", ["(default foo", "         bar)"]],
	["not defer", ["(defer   foo", "         bar)"]],
	["not deflate", ["(deflate foo", "         bar)"]],
	["empty let", ["(let []", "  )"]],
	["cond closer", ["(cond foo", "      )"]],
	["cond", ["(cond foo", "      bar)"]],
	["vector closer", ["[", " ]"]],
	["list closer", ["(foo", " )"]],
	["letfn block", ["(letfn [(f [x]", "          x)]", "  (let [x (f 1)]", "    (str x 2", "         3 4)))"]],
	["let block", ["(let [x 1]", "  (+ x 1))"]],
	["let* block", ["(let* [x 1]", "  (+ x 1))"]],
	["multiline right hand side", ["(list foo :bar (fn a", "                 ([] nil)", "                 ([b] b)))"]],
	["reader conditional", ["#?(:clj foo", "   :cljs bar)"]],
	["splicing reader conditional", ["#?@(:clj foo", "    :cljs bar)"]],
	["namespaced map", ["#:clj {:a :b", "       :c :d}"]],
];

// cljfmt 0.16.0's output with default options: it leaves `#_` forms out
// of an element's index but aligns with the form after the head even
// when that is one.
const DISCARD_CASES: [string, string[]][] = [
	["aligns with a discarded first argument", ["(foo #_a b", "     c)"]],
	["aligns with the first of two discarded arguments", ["(foo #_a #_b c", "     d)"]],
	["counts no discarded form", ["(foo", " #_a b", " c)"]],
	["block after a discarded argument", ["(if #_x y", "    z)"]],
];

describe("cljfmt's default indentation", () => {
	for (const [name, lines] of [...CLJFMT_CASES, ...DISCARD_CASES]) {
		test(name, () => {
			const state = stateOf(lines.join("\n"));
			for (let n = 2; n <= state.doc.lines; n++) {
				const line = state.doc.line(n);
				// cljfmt leaves blank and comment-only lines alone.
				if (line.text.trim() === "" || line.text.trim().startsWith(";")) continue;
				const expected = line.text.length - line.text.trimStart().length;
				expect(getIndentation(state, line.from), `line ${n}: ${line.text}`).toBe(expected);
			}
		});
	}
});

// Enter at the end of a line: the new line gets the indentation cljfmt
// gives an element starting it.
function enter(doc: string, at: number): string {
	let tr: Transaction | null = null;
	insertNewlineAndIndent({ state: stateOf(doc, at), dispatch: (t) => (tr = t) });
	if (!tr) throw new Error("Enter did nothing");
	return (tr as Transaction).state.doc.toString();
}

describe("Enter", () => {
	test("aligns a call's next argument with its first", () => {
		expect(enter('(println "x" x)', 14)).toBe('(println "x" x\n         )');
	});

	test("indents one space before a call's first argument", () => {
		expect(enter("(println)", 8)).toBe("(println\n )");
	});

	test("indents a body two spaces", () => {
		expect(enter("(when (pos? x))", 14)).toBe("(when (pos? x)\n  )");
		expect(enter("(defn f [a])", 11)).toBe("(defn f [a]\n  )");
	});

	test("keeps the text after the caret on the new line", () => {
		expect(enter("(let [x 1] x)", 10)).toBe("(let [x 1]\n  x)");
	});

	test("indents inside a list its closer is cut off from", () => {
		expect(enter("  (let [x 1]\n    (+ x a)", 24)).toBe("  (let [x 1]\n    (+ x a)\n    ");
	});

	test("returns to column 0 after a top-level form", () => {
		expect(enter("(def x 1)", 9)).toBe("(def x 1)\n");
	});

	test("leaves a line inside a string as it is", () => {
		expect(enter('  "ab"', 4)).toBe('  "a\n  b"');
	});
});

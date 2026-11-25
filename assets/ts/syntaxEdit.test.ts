import { describe, expect, test } from "bun:test";
import { cpp } from "@codemirror/lang-cpp";
import { javascript } from "@codemirror/lang-javascript";
import { json } from "@codemirror/lang-json";
import { python } from "@codemirror/lang-python";
import type { LanguageSupport } from "@codemirror/language";
import { EditorSelection, EditorState, type Extension, type TransactionSpec } from "@codemirror/state";
import { clojure } from "@nextjournal/lang-clojure";
import {
	expandSelection,
	joinLines,
	moveNode,
	parsed,
	selectionHistory,
	shrinkSelection,
	type Tight,
} from "./syntaxEdit";

/** A state from `marked`, whose `|` marks the caret, or `<` and `>` the
 *  selection. */
function stateOf(marked: string, language: LanguageSupport | Extension = []): EditorState {
	let selection: EditorSelection;
	let doc = marked;
	if (marked.includes("|")) {
		selection = EditorSelection.cursor(marked.indexOf("|"));
		doc = marked.replace("|", "");
	} else {
		const from = marked.indexOf("<");
		doc = marked.replace("<", "");
		const to = doc.indexOf(">");
		doc = doc.replace(">", "");
		selection = EditorSelection.single(from, to);
	}
	const state = EditorState.create({ doc, selection, extensions: [language, selectionHistory] });
	return parsed(state, 5000);
}

/** The text with the selection marked as `stateOf` reads it. */
function marked(state: EditorState): string {
	const { from, to, empty } = state.selection.main;
	const doc = state.doc.toString();
	if (empty) return `${doc.slice(0, from)}|${doc.slice(from)}`;
	return `${doc.slice(0, from)}<${doc.slice(from, to)}>${doc.slice(to)}`;
}

function apply(state: EditorState, spec: TransactionSpec | null): EditorState {
	if (!spec) throw new Error("command did nothing");
	return state.update(spec).state;
}

describe("expandSelection", () => {
	test("grows from the word through each bracket's inside and the node", () => {
		let state = stateOf("(foo (b|ar baz))", clojure());
		const steps: string[] = [];
		for (let i = 0; i < 5; i++) {
			state = apply(state, expandSelection(state));
			steps.push(marked(state));
		}
		expect(steps).toEqual([
			"(foo (<bar> baz))",
			"(foo (<bar baz>))",
			"(foo <(bar baz)>)",
			"(<foo (bar baz)>)",
			"<(foo (bar baz))>",
		]);
		expect(expandSelection(state)).toBeNull();
	});

	test("selects the whole form from a caret just before its opener or after its closer", () => {
		const expand = (doc: string, language: LanguageSupport) => {
			const state = stateOf(doc, language);
			return marked(apply(state, expandSelection(state)));
		};
		const prefixed = ["'#{b}", "@(b)", "#:n{:b 1}", "^:m (e)", "#^:m (e)", "^{:m 1} (e)", "#^{:m 1} (e)", '#inst "x"', "#my.Rec{:b 1}", "#my.Rec[1]"];
		for (const form of ["(b)", "[b]", "{:b c}", "#{b}", '"b c"', ...prefixed]) {
			expect(expand(`(a |${form} d)`, clojure())).toBe(`(a <${form}> d)`);
			expect(expand(`(a ${form}| d)`, clojure())).toBe(`(a <${form}> d)`);
			expect(expand(`(a ${form}|)`, clojure())).toBe(`(a <${form}>)`);
		}
		for (const form of ["(b)", "[b]", "{b}", '"b"', "'b'", "`b`", "-(b)"]) {
			expect(expand(`f(a, |${form});`, javascript())).toBe(`f(a, <${form}>);`);
			expect(expand(`f(a, ${form}|);`, javascript())).toBe(`f(a, <${form}>);`);
		}
		expect(expand(`f(a, "b\\n"|);`, javascript())).toBe(`f(a, <"b\\n">);`);
		expect(expand(`f(a, f'{b}'|)`, python())).toBe(`f(a, <f'{b}'>)`);
		expect(expand(`f(a, u8"b"|);`, cpp())).toBe(`f(a, <u8"b">);`);
		for (const form of ["#|(inc %)", "@|(b)", "'|#{b}", "'#|{b}", "#?|@(:clj [b])", "#::|{:b 1}", "^:m |(e)"]) {
			expect(expand(`(a ${form} d)`, clojure())).toBe(`(a <${form.replace("|", "")}> d)`);
		}
		expect(expand("f(a, -|(b));", javascript())).toBe("f(a, <-(b)>);");
		expect(expand("x = |[a][0];", javascript())).toBe("x = <[a]>[0];");
		expect(expand('x = |"a"[0];', javascript())).toBe('x = <"a">[0];');
		expect(expand("((b)| d)", clojure())).toBe("(<(b)> d)");
		expect(expand(";;\n(b)|", clojure())).toBe(";;\n<(b)>");
		expect(expand("(a (b)|[c])", clojure())).toBe("(a (b)<[c]>)");
	});

	test("takes no string, name or operator before a form's opener as its prefix", () => {
		const expand = (doc: string) => {
			const state = stateOf(doc, javascript());
			return marked(apply(state, expandSelection(state)));
		};
		expect(expand('x = |"(" + f(y);')).toBe('x = <"("> + f(y);');
		expect(expand('x = "-" + (y)|;')).toBe('x = "-" + <(y)>;');
		expect(expand("_ = (a)|;")).toBe("_ = <(a)>;");
		expect(expand("$ = (a)|;")).toBe("$ = <(a)>;");
		expect(expand("x = |!f(y);")).toBe("x = <!>f(y);");
	});

	test("grows by syntax in other languages", () => {
		let state = stateOf("f(a, |b + 1);", javascript());
		state = apply(state, expandSelection(state));
		state = apply(state, expandSelection(state));
		expect(marked(state)).toBe("f(a, <b + 1>);");
	});

	test("does nothing without a grammar", () => {
		expect(expandSelection(stateOf("a b|"))).toBeNull();
	});
});

describe("shrinkSelection", () => {
	test("steps back through the expansions", () => {
		let state = stateOf("[1, [|2, 3]]", json());
		const start = marked(state);
		state = apply(state, expandSelection(state));
		const first = marked(state);
		state = apply(state, expandSelection(state));
		state = apply(state, shrinkSelection(state));
		expect(marked(state)).toBe(first);
		state = apply(state, shrinkSelection(state));
		expect(marked(state)).toBe(start);
		expect(shrinkSelection(state)).toBeNull();
	});

	test("forgets the expansions once the selection moves", () => {
		let state = stateOf("[1, [|2, 3]]", json());
		state = apply(state, expandSelection(state));
		state = state.update({ selection: EditorSelection.cursor(0) }).state;
		expect(shrinkSelection(state)).toBeNull();
	});
});

describe("moveNode", () => {
	const move = (doc: string, language: LanguageSupport, dir: -1 | 1) => {
		const state = stateOf(doc, language);
		const spec = moveNode(state, dir);
		return spec ? marked(state.update(spec).state) : null;
	};

	test("swaps an argument with the next", () => {
		expect(move("f(|a, b)", javascript(), 1)).toBe("f(b, |a)");
	});

	test("moves a statement past the previous one, a line at a time", () => {
		expect(move("def f():\n    x = 1\n    re|turn x\n", python(), -1)).toBe("def f():\n    re|turn x\n    x = 1\n");
	});

	test("moves a block statement as whole lines", () => {
		expect(move("def f(x):\n    if x:\n        y = 1\n    re|turn 0\n", python(), -1)).toBe(
			"def f(x):\n    re|turn 0\n    if x:\n        y = 1\n",
		);
		expect(move("|if x:\n    y = 1\nz = 1\n", python(), 1)).toBe("z = 1\n|if x:\n    y = 1\n");
	});

	test("moves an object property, not its key past its value", () => {
		expect(move('{"a": |1, "b": 2}', json(), 1)).toBe('{"b": 2, "a": |1}');
	});

	test("moves a dict entry whose key and value are siblings", () => {
		expect(move("d = {'a': 1, |'b': 2}", python(), -1)).toBe("d = {|'b': 2, 'a': 1}");
	});

	test("moves a typed parameter with its type", () => {
		expect(move("function g(|p: P, q: number) {}", javascript({ typescript: true }), 1)).toBe(
			"function g(q: number, |p: P) {}",
		);
	});

	test("moves one name of a comma list without brackets", () => {
		expect(move("|a, b = 1, 2", python(), 1)).toBe("b, |a = 1, 2");
	});

	test("moves a whole statement from its first name", () => {
		expect(move("const |x = 1;\nfoo();", javascript(), 1)).toBe("foo();\nconst |x = 1;");
	});

	test("moves a Clojure form among its siblings", () => {
		expect(move("(a (b |c) d)", clojure(), -1)).toBe("(a (|c b) d)");
		expect(move("(a |(b c) d)", clojure(), 1)).toBe("(a d |(b c))");
	});

	test("leaves a Clojure list cut off from its closer alone", () => {
		expect(move("|x\n(let [b", clojure(), 1)).toBeNull();
		expect(move("x\n(let [|b", clojure(), -1)).toBeNull();
	});

	test("moves no item of a comma list that holds a syntax error", () => {
		expect(move("[|1, 2 3]", javascript(), 1)).toBeNull();
		expect(move("[1, 2 |3]", javascript(), -1)).toBeNull();
	});

	test("moves the node a selection covers", () => {
		expect(move("(a <(b c)> d)", clojure(), 1)).toBe("(a d <(b c)>)");
	});

	test("does nothing at the first or last node", () => {
		expect(move("[|1]", json(), 1)).toBeNull();
	});

	test("does nothing without a grammar", () => {
		expect(moveNode(stateOf("a\nb|"), -1)).toBeNull();
	});
});

describe("joinLines", () => {
	const join = (doc: string, tight?: Tight) => {
		const state = stateOf(doc);
		const spec = joinLines(state, tight);
		return spec ? marked(state.update(spec).state) : null;
	};

	test("joins the next line with one space", () => {
		expect(join("fo|o  \n    bar\nbaz")).toBe("foo| bar\nbaz");
	});

	test("joins every selected line", () => {
		expect(join("<a\n b\n c>\nd")).toBe("<a b c>\nd");
	});

	test("drops a blank line and keeps the next one's indentation", () => {
		expect(join("|\n  a")).toBe("|  a");
		expect(join("a|\n\nb")).toBe("a|\nb");
	});

	test("joins selected lines across blank lines with one space", () => {
		expect(join("<foo\n\nbar>")).toBe("<foo bar>");
		expect(join("<foo\n  \n  bar>")).toBe("<foo bar>");
		expect(join("<\n\n  a\nb>")).toBe("<  a b>");
	});

	test("keeps one blank line when all are blank", () => {
		expect(join("|\n\nb")).toBe("|\nb");
	});

	test("adds no space where tight says so", () => {
		const char = (s: EditorState, at: number) => s.doc.sliceString(at, at + 1);
		const tight: Tight = (s, end, start) => char(s, end - 1) === "(" || char(s, start) === ")";
		expect(join("(foo|\n  bar\n  )", tight)).toBe("(foo| bar\n  )");
		expect(join("(|\n  bar)", tight)).toBe("(|bar)");
	});

	test("does nothing on the last line", () => {
		expect(join("a\nb|")).toBeNull();
	});
});

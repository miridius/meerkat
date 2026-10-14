import { describe, expect, test } from "bun:test";
import { javascript } from "@codemirror/lang-javascript";
import { json } from "@codemirror/lang-json";
import { python } from "@codemirror/lang-python";
import { ensureSyntaxTree, type LanguageSupport } from "@codemirror/language";
import { EditorSelection, EditorState, type Extension, type TransactionSpec } from "@codemirror/state";
import { clojure } from "@nextjournal/lang-clojure";
import { expandSelection, joinLines, moveNode, selectionHistory, shrinkSelection } from "./syntaxEdit";

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
	ensureSyntaxTree(state, doc.length, 5000);
	return state.update({}).state;
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

	test("moves an object property, not its key past its value", () => {
		expect(move('{"a": |1, "b": 2}', json(), 1)).toBe('{"b": 2, "a": |1}');
	});

	test("moves a whole statement from its first name", () => {
		expect(move("const |x = 1;\nfoo();", javascript(), 1)).toBe("foo();\nconst |x = 1;");
	});

	test("moves a Clojure form among its siblings", () => {
		expect(move("(a (b |c) d)", clojure(), -1)).toBe("(a (|c b) d)");
		expect(move("(a |(b c) d)", clojure(), 1)).toBe("(a d |(b c))");
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
	const join = (doc: string, tight?: (a: string, b: string) => boolean) => {
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

	test("adds no space where tight says so", () => {
		expect(join("(foo|\n  bar\n  )", (a, b) => a === "(" || b === ")")).toBe("(foo| bar\n  )");
		expect(join("(|\n  bar)", (a) => a === "(")).toBe("(|bar)");
	});

	test("does nothing on the last line", () => {
		expect(join("a\nb|")).toBeNull();
	});
});

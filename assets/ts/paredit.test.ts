import { describe, expect, test } from "bun:test";
import { ensureSyntaxTree, LanguageSupport } from "@codemirror/language";
import { EditorSelection, EditorState, type TransactionSpec } from "@codemirror/state";
import { clojureLanguage } from "@nextjournal/lang-clojure";
import { clojureIndent } from "./clojureIndent";
import {
	barfBackward,
	barfForward,
	deleteGuarded,
	formStep,
	raise,
	slurpBackward,
	slurpForward,
	splice,
	tightInClojure,
	typeBracket,
} from "./paredit";

const clojure = new LanguageSupport(clojureLanguage, clojureIndent);

/** A Clojure state from `doc`, whose `|` marks the caret. */
function stateOf(marked: string): EditorState {
	const pos = marked.indexOf("|");
	const doc = marked.replace("|", "");
	const state = EditorState.create({
		doc,
		selection: EditorSelection.cursor(pos),
		extensions: [clojure, EditorState.allowMultipleSelections.of(true)],
	});
	ensureSyntaxTree(state, doc.length, 5000);
	return state.update({}).state;
}

/** The text, with `|` at the caret, after `command`; null when it does
 *  nothing. */
function run(command: (s: EditorState) => TransactionSpec | null, marked: string): string | null {
	const state = stateOf(marked);
	const spec = command(state);
	if (!spec) return null;
	const next = state.update(spec).state;
	const head = next.selection.main.head;
	const doc = next.doc.toString();
	return `${doc.slice(0, head)}|${doc.slice(head)}`;
}

describe("slurpForward", () => {
	test("pulls the next form in", () => {
		expect(run(slurpForward, "(a |b) c d")).toBe("(a |b c) d");
	});

	test("into an empty list, without a space", () => {
		expect(run(slurpForward, "(|) c")).toBe("(|c)");
	});

	test("keeps forms apart when nothing parted them", () => {
		expect(run(slurpForward, '(a|)"s"')).toBe('(a| "s")');
	});

	test("climbs to a list that has a next form", () => {
		expect(run(slurpForward, "((a|)) b")).toBe("((a|) b)");
	});

	test("keeps a quote or set prefix with the slurped form", () => {
		expect(run(slurpForward, "[a|] '(b) #{c}")).toBe("[a| '(b)] #{c}");
	});

	test("does nothing with no next form", () => {
		expect(run(slurpForward, "(a|)")).toBeNull();
	});

	test("does nothing in a list the editor cut off from its closer", () => {
		expect(run(slurpForward, "(a| b")).toBeNull();
	});

	test("slurps from a list the editor cut off from its closer", () => {
		expect(run(slurpForward, "(foo (a|) b")).toBe("(foo (a| b)");
	});

	test("does nothing past a closer the editor cut off from its opener", () => {
		expect(run(slurpForward, "(f|oo a)) b")).toBeNull();
	});

	test("does not pull in a list the editor cut off from its closer", () => {
		expect(run(slurpForward, "(f|oo) (g b")).toBeNull();
	});

	test("re-indents the slurped lines", () => {
		expect(run(slurpForward, "(let [x 1]\n  (foo |x))\n(bar\n y)")).toBe(
			"(let [x 1]\n  (foo |x)\n  (bar\n   y))",
		);
	});
});

describe("structural commands with several carets", () => {
	test("change a list once when two carets share it", () => {
		const state = stateOf("(a b) c");
		const two = state.update({
			selection: EditorSelection.create([EditorSelection.cursor(2), EditorSelection.cursor(4)]),
		}).state;
		for (const command of [slurpForward, barfForward, splice, raise]) {
			const next = two.update(command(two) as TransactionSpec).state.doc.toString();
			expect([command.name, next]).toEqual([
				command.name,
				{ slurpForward: "(a b c)", barfForward: "(a) b c", splice: "a b c", raise: "a c" }[command.name],
			]);
		}
	});
});

describe("cut-off lists", () => {
	test("barf, splice and raise leave a list cut off from its closer alone", () => {
		for (const command of [barfForward, barfBackward, splice, raise]) {
			expect([command.name, run(command, "(a b| c")]).toEqual([command.name, null]);
		}
	});
});

describe("barfForward", () => {
	test("pushes the last form out", () => {
		expect(run(barfForward, "(a |b c)")).toBe("(a |b) c");
	});

	test("leaves an empty list", () => {
		expect(run(barfForward, "(|a)")).toBe("(|) a");
	});

	test("does nothing in an empty list", () => {
		expect(run(barfForward, "(|)")).toBeNull();
	});

	test("re-indents the barfed lines", () => {
		expect(run(barfForward, "(do\n  (a)|\n  (b\n   c))")).toBe("(do\n  (a)|)\n(b\n c)");
	});
});

describe("slurpBackward", () => {
	test("pulls the previous form in", () => {
		expect(run(slurpBackward, "a b (|c)")).toBe("a (b |c)");
	});

	test("moves a prefix with the opener", () => {
		expect(run(slurpBackward, "a #{|b}")).toBe("#{a |b}");
	});

	test("into an empty list", () => {
		expect(run(slurpBackward, "a (|)")).toBe("(a|)");
	});

	test("keeps forms apart when nothing parted them", () => {
		expect(run(slurpBackward, '"s"(|b)')).toBe('("s" |b)');
	});

	test("does nothing with no previous form", () => {
		expect(run(slurpBackward, "(|a)")).toBeNull();
	});

	test("does nothing past a closer the editor cut off from its opener", () => {
		expect(run(slurpBackward, 'z "s"] (f|oo y)')).toBeNull();
	});
});

describe("barfBackward", () => {
	test("pushes the first form out", () => {
		expect(run(barfBackward, "(a b |c)")).toBe("a (b |c)");
	});

	test("moves a prefix with the opener", () => {
		expect(run(barfBackward, "'(a |b)")).toBe("a '(|b)");
	});

	test("leaves an empty list", () => {
		expect(run(barfBackward, "(a|)")).toBe("a (|)");
	});
});

describe("splice", () => {
	test("removes the brackets", () => {
		expect(run(splice, "(a [b |c] d)")).toBe("(a b |c d)");
	});

	test("removes a set's #", () => {
		expect(run(splice, "#{a |b}")).toBe("a |b");
	});

	test("does nothing at the top level", () => {
		expect(run(splice, "a |b")).toBeNull();
	});
});

describe("raise", () => {
	test("replaces the parent with the form at the caret", () => {
		expect(run(raise, "(foo (bar| baz))")).toBe("(foo bar|)");
	});

	test("takes the next form from whitespace", () => {
		expect(run(raise, "(foo | (bar))")).toBe("|(bar)");
	});

	test("replaces a prefixed parent whole", () => {
		expect(run(raise, "[x '(a |b)]")).toBe("[x |b]");
	});

	test("re-indents the raised lines", () => {
		expect(run(raise, "(let [x 1]\n  (when x\n    |(foo a\n         b)))")).toBe(
			"(let [x 1]\n  |(foo a\n       b))",
		);
	});

	test("does nothing at the top level", () => {
		expect(run(raise, "a |b")).toBeNull();
	});
});

describe("formStep", () => {
	const step = (marked: string, dir: -1 | 1) => {
		const state = stateOf(marked);
		const to = formStep(state, state.selection.main.head, dir);
		const doc = state.doc.toString();
		return `${doc.slice(0, to)}|${doc.slice(to)}`;
	};

	test("moves past the next form", () => {
		expect(step("(a| (b c) d)", 1)).toBe("(a (b c)| d)");
	});

	test("moves to the end of the form the caret is in", () => {
		expect(step("(fo|o bar)", 1)).toBe("(foo| bar)");
	});

	test("moves out past the closer after the last form", () => {
		expect(step("(a (b c|) d)", 1)).toBe("(a (b c)| d)");
	});

	test("moves back before the previous form", () => {
		expect(step("(a (b c) |d)", -1)).toBe("(a |(b c) d)");
	});

	test("moves out before the opener and its prefix", () => {
		expect(step("(a '(|b))", -1)).toBe("(a |'(b))");
	});

	test("stays at either end of the editor", () => {
		expect(step("a|", 1)).toBe("a|");
		expect(step("|a", -1)).toBe("|a");
	});

	test("skips comments", () => {
		expect(step("(a| ; c\n b)", 1)).toBe("(a ; c\n b|)");
	});
});

describe("deleteGuarded", () => {
	const back = (marked: string) => run((s) => deleteGuarded(s, -1), marked);
	const fwd = (marked: string) => run((s) => deleteGuarded(s, 1), marked);

	test("Backspace steps over a matched closer or opener", () => {
		expect(back("(a b)|")).toBe("(a b|)");
		expect(back("(|a b)")).toBe("|(a b)");
	});

	test("Delete steps over a matched opener or closer", () => {
		expect(fwd("|(a b)")).toBe("(|a b)");
		expect(fwd("(a b|)")).toBe("(a b)|");
	});

	test("either deletes an empty pair from inside", () => {
		expect(back("x [|] y")).toBe("x | y");
		expect(fwd("x {|} y")).toBe("x | y");
	});

	test("deletes an empty set or anonymous function with its #", () => {
		expect(back("x #{|} y")).toBe("x | y");
		expect(fwd("#(|)")).toBe("|");
	});

	test("steps over a # prefix with its opener", () => {
		expect(back("x #{|a b}")).toBe("x |#{a b}");
		expect(back("x #|{a b}")).toBe("x |#{a b}");
		expect(back("#?(|:clj a)")).toBe("|#?(:clj a)");
		expect(fwd("x |#{a b}")).toBe("x #{|a b}");
		expect(fwd("|#?(:clj a)")).toBe("#?(|:clj a)");
	});

	test("lets an unmatched bracket be deleted", () => {
		expect(back("a)|")).toBeNull();
		expect(back("(|foo\n  bar")).toBeNull();
		expect(fwd("|]")).toBeNull();
	});

	test("lets a bracket in a string or comment be deleted", () => {
		expect(back('"(|"')).toBeNull();
		expect(back("; (|")).toBeNull();
	});

	test("leaves a selection to the editor", () => {
		const state = stateOf("(a)");
		const selected = state.update({ selection: EditorSelection.range(0, 3) }).state;
		expect(deleteGuarded(selected, -1)).toBeNull();
	});

	test("deletes plainly at other carets when one is guarded", () => {
		const state = stateOf("(a) b");
		const two = state.update({
			selection: EditorSelection.create([EditorSelection.cursor(3), EditorSelection.cursor(5)]),
		}).state;
		const next = two.update(deleteGuarded(two, -1) as TransactionSpec).state;
		expect(next.doc.toString()).toBe("(a) ");
		expect(next.selection.ranges.map((r) => r.head)).toEqual([2, 4]);
	});
});

describe("typeBracket", () => {
	const type = (text: string, marked: string) => run((s) => typeBracket(s, text), marked);

	test("an opener brings its closer", () => {
		expect(type("(", "a |b")).toBe("a (|)b");
		expect(type("{", "#|")).toBe("#{|}");
	});

	test("an opener wraps a selection", () => {
		const state = stateOf("a b").update({ selection: EditorSelection.range(2, 3) }).state;
		const next = state.update(typeBracket(state, "[") as TransactionSpec).state;
		expect(next.doc.toString()).toBe("a [b]");
		expect([next.selection.main.from, next.selection.main.to]).toEqual([3, 4]);
	});

	test("a closer steps over the same matched closer", () => {
		expect(type(")", "(a|)")).toBe("(a)|");
	});

	test("a closer is typed as text before another closer or an unmatched one", () => {
		expect(type(")", "[a|]")).toBeNull();
		expect(type(")", "a|)")).toBeNull();
	});

	test("brackets in a string, a comment or after a backslash are text", () => {
		expect(type("(", '"a|"')).toBeNull();
		expect(type("(", "; a|")).toBeNull();
		expect(type("(", "\\|")).toBeNull();
	});

	test("other text is left to the editor", () => {
		expect(type("'", "a|")).toBeNull();
	});
});

describe("tightInClojure", () => {
	// `|` marks where the line before ends and `^` where the next starts.
	const tight = (marked: string) => {
		const end = marked.indexOf("|");
		const doc = marked.replace("|", "");
		const start = doc.indexOf("^");
		return tightInClojure(stateOf(`|${doc.replace("^", "")}`), end, start);
	};

	test("wants no space after an opener or before a closer", () => {
		expect(tight("(|\n^a)")).toBe(true);
		expect(tight("[a|\n^]")).toBe(true);
		expect(tight("(a|\n^b)")).toBe(false);
	});

	test("treats a bracket character literal as a form", () => {
		expect(tight("(\\(|\n ^a)")).toBe(false);
		expect(tight("(a|\n ^\\))")).toBe(false);
	});
});

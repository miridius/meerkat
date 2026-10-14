import { describe, expect, test } from "bun:test";
import { javascript } from "@codemirror/lang-javascript";
import { ensureSyntaxTree, LanguageSupport } from "@codemirror/language";
import { EditorSelection, EditorState, type Extension, type Transaction, type TransactionSpec } from "@codemirror/state";
import type { EditorView } from "@codemirror/view";
import { clojureLanguage } from "@nextjournal/lang-clojure";
import { clojureIndent } from "./clojureIndent";
import { cheatSheet, editorKeys, hotkeyBindings, keyLabel } from "./editorKeys";

const clojure = new LanguageSupport(clojureLanguage, clojureIndent);

function stateOf(marked: string, extensions: Extension[]): EditorState {
	const pos = marked.indexOf("|");
	const doc = marked.replace("|", "");
	const state = EditorState.create({ doc, selection: EditorSelection.cursor(pos), extensions });
	ensureSyntaxTree(state, doc.length, 5000);
	return state.update({}).state;
}

function marked(state: EditorState): string {
	const doc = state.doc.toString();
	const { head } = state.selection.main;
	return `${doc.slice(0, head)}|${doc.slice(head)}`;
}

/** Press `key` (CodeMirror's name for it, as bound off macOS) in a file
 *  in `language`: the text after, and whether the key was claimed. */
function press(key: string, language: string, hasGrammar: boolean, state: EditorState) {
	const binding = hotkeyBindings(language, hasGrammar).find((b) => b.key === key);
	if (!binding?.run) return { claimed: false, text: marked(state) };
	let next = state;
	const view = {
		state,
		dispatch: (spec: TransactionSpec | Transaction) => {
			next = "startState" in spec ? spec.state : state.update(spec).state;
		},
	} as unknown as EditorView;
	const claimed = binding.run(view);
	return { claimed, text: marked(next) };
}

describe("hotkeyBindings", () => {
	test("Clojure gets the structural keys", () => {
		const state = stateOf("(a |b) c", [clojure]);
		expect(press("Mod-Shift-k", "clojure", true, state)).toEqual({ claimed: true, text: "(a |b c)" });
		expect(press("Ctrl-Alt-k", "clojure", true, state)).toEqual({ claimed: true, text: "a (|b) c" });
		expect(press("Alt-ArrowRight", "clojure", true, state)).toEqual({ claimed: true, text: "(a b|) c" });
	});

	test("⌥S splices, under either name macOS gives it", () => {
		const state = stateOf("(a |b)", [clojure]);
		expect(press("Alt-s", "clojure", true, state).text).toBe("a |b");
		expect(press("Alt-ß", "clojure", true, state).text).toBe("a |b");
	});

	test("a Clojure key that does nothing still claims the key", () => {
		const state = stateOf("a |b", [clojure]);
		expect(press("Mod-Shift-k", "clojure", true, state)).toEqual({ claimed: true, text: "a |b" });
	});

	test("outside Clojure ⇧⌘K is left to CodeMirror's delete line", () => {
		const keys = hotkeyBindings("javascript", true).map((b) => b.key);
		expect(keys).not.toContain("Mod-Shift-k");
		expect(keys).toContain("Mod-Shift-ArrowUp");
	});

	test("⌥⇧↑ moves the line in a file with no grammar, and ⌥↑ does nothing", () => {
		const state = stateOf("a\nb|", []);
		expect(press("Alt-Shift-ArrowUp", "text", false, state)).toEqual({ claimed: true, text: "b|\na" });
		expect(press("Alt-ArrowUp", "text", false, state)).toEqual({ claimed: true, text: "a\nb|" });
		expect(hotkeyBindings("text", false).map((b) => b.key)).not.toContain("Mod-Shift-ArrowUp");
	});

	test("join lines leaves no space after an opener in Clojure only", () => {
		expect(press("Alt-j", "clojure", true, stateOf("(|\n a)", [clojure])).text).toBe("(|a)");
		expect(press("Alt-j", "javascript", true, stateOf("f(|\n a)", [javascript()])).text).toBe("f(| a)");
	});

	test("join lines is ⌃J on macOS", () => {
		const join = hotkeyBindings("text", false).find((b) => b.key === "Alt-j");
		expect(join?.mac).toBe("Ctrl-j");
	});

	test("moving a Clojure form re-indents it", () => {
		const state = stateOf("(do\n  |(foo a\n       b)\n  (bar))", [clojure]);
		expect(press("Mod-Shift-ArrowDown", "clojure", true, state).text).toBe("(do\n  (bar)\n  |(foo a\n       b))");
		const nested = stateOf("(let [x (a\n         b)]\n  |(c))", [clojure]);
		expect(press("Mod-Shift-ArrowUp", "clojure", true, nested).text).toBe("(let |(c)\n  [x (a\n      b)])");
	});

	test("Backspace beside a matched bracket steps over it, and falls through elsewhere", () => {
		expect(press("Backspace", "clojure", true, stateOf("(a)|", [clojure]))).toEqual({
			claimed: true,
			text: "(a|)",
		});
		expect(press("Backspace", "clojure", true, stateOf("a)|", [clojure])).claimed).toBe(false);
	});
});

describe("editorKeys", () => {
	test("a paste into Clojure re-indents its lines", () => {
		const state = stateOf("(let [x 1]\n  |)", [clojure, editorKeys("clojure", true)]);
		const next = state.update({
			changes: { from: state.selection.main.head, insert: "(foo a\nb)" },
			userEvent: "input.paste",
		}).state;
		expect(next.doc.toString()).toBe("(let [x 1]\n  (foo a\n       b))");
	});

	test("typing elsewhere is left alone", () => {
		const state = stateOf("(let [x 1]\n  |)", [clojure, editorKeys("clojure", true)]);
		const next = state.update({ changes: { from: 13, insert: "\nb" }, userEvent: "input.type" }).state;
		expect(next.doc.toString()).toBe("(let [x 1]\n  \nb)");
	});
});

describe("keyLabel", () => {
	test("writes macOS symbols in Apple's order", () => {
		expect(keyLabel("Mod-Shift-k", true)).toBe("⇧⌘K");
		expect(keyLabel("Alt-Shift-ArrowUp", true)).toBe("⌥⇧↑");
		expect(keyLabel({ mac: "Ctrl-Cmd-j", other: "Ctrl-Alt-j" }, true)).toBe("⌃⌘J");
		expect(keyLabel("Mod-'", true)).toBe("⌘'");
	});

	test("writes names elsewhere", () => {
		expect(keyLabel("Mod-Shift-k", false)).toBe("Ctrl+Shift+K");
		expect(keyLabel({ mac: "Ctrl-Cmd-j", other: "Ctrl-Alt-j" }, false)).toBe("Ctrl+Alt+J");
		expect(keyLabel({ mac: "Ctrl-j", other: "Alt-j" }, false)).toBe("Alt+J");
	});
});

describe("cheatSheet", () => {
	test("lists the keys for the file's language", () => {
		const keys = (language: string, grammar: boolean) => cheatSheet(language, grammar, true).map((r) => r.keys);
		expect(keys("text", false)).toEqual(["⌥⇧↑ / ⌥⇧↓", "⌃J"]);
		expect(keys("python", true)).toEqual(["⌥⇧↑ / ⌥⇧↓", "⌃J", "⌥↑ / ⌥↓", "⇧⌘↑ / ⇧⌘↓"]);
		expect(keys("clojure", true)).toEqual([
			"⌥⇧↑ / ⌥⇧↓",
			"⌃J",
			"⌥↑ / ⌥↓",
			"⇧⌘↑ / ⇧⌘↓",
			"⌥← / ⌥→",
			"⇧⌘K / ⇧⌘J",
			"⌃⌘J / ⌃⌘K",
			"⌘'",
			"⌥S",
		]);
	});
});

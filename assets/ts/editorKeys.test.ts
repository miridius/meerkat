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

/** Press `key` (CodeMirror's name for it, as bound on macOS) in a file
 *  in `language`: the text after, and whether the key was claimed. */
function press(key: string, language: string, state: EditorState) {
	const binding = hotkeyBindings(language).find((b) => (b.mac ?? b.key) === key);
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
		expect(press("Mod-Shift-k", "clojure", state)).toEqual({ claimed: true, text: "(a |b c)" });
		expect(press("Ctrl-Cmd-k", "clojure", state)).toEqual({ claimed: true, text: "a (|b) c" });
		expect(press("Alt-ArrowRight", "clojure", state)).toEqual({ claimed: true, text: "(a b|) c" });
	});

	test("⌥S splices, under either name macOS gives it", () => {
		const state = stateOf("(a |b)", [clojure]);
		expect(press("Alt-s", "clojure", state).text).toBe("a |b");
		expect(press("Alt-ß", "clojure", state).text).toBe("a |b");
	});

	test("a Clojure key that does nothing still claims the key", () => {
		const state = stateOf("a |b", [clojure]);
		expect(press("Mod-Shift-k", "clojure", state)).toEqual({ claimed: true, text: "a |b" });
	});

	test("outside Clojure ⇧⌘K is left to CodeMirror's delete line", () => {
		const keys = hotkeyBindings("javascript").map((b) => b.mac);
		expect(keys).not.toContain("Mod-Shift-k");
		expect(keys).toContain("Mod-Shift-ArrowUp");
	});

	test("⌥⇧↑ moves the line in a file with no grammar, and ⌥↑ does nothing", () => {
		const state = stateOf("a\nb|", []);
		expect(press("Alt-Shift-ArrowUp", "text", state)).toEqual({ claimed: true, text: "b|\na" });
		expect(press("Alt-ArrowUp", "text", state)).toEqual({ claimed: true, text: "a\nb|" });
		expect(hotkeyBindings("text").map((b) => b.mac)).not.toContain("Mod-Shift-ArrowUp");
	});

	test("join lines leaves no space after an opener in Clojure only", () => {
		expect(press("Ctrl-j", "clojure", stateOf("(|\n a)", [clojure])).text).toBe("(|a)");
		expect(press("Ctrl-j", "javascript", stateOf("f(|\n a)", [javascript()])).text).toBe("f(| a)");
	});

	test("the hotkeys bind on macOS only, and Backspace and Delete everywhere", () => {
		const bindings = hotkeyBindings("clojure");
		expect(bindings.filter((b) => b.key).map((b) => b.key)).toEqual(["Backspace", "Delete"]);
		expect(bindings.filter((b) => !b.key).every((b) => b.mac)).toBe(true);
		expect(hotkeyBindings("text").every((b) => !b.key && b.mac)).toBe(true);
	});

	test("moving a Clojure form re-indents it", () => {
		const state = stateOf("(do\n  |(foo a\n       b)\n  (bar))", [clojure]);
		expect(press("Mod-Shift-ArrowDown", "clojure", state).text).toBe("(do\n  (bar)\n  |(foo a\n       b))");
		const nested = stateOf("(let [x (a\n         b)]\n  |(c))", [clojure]);
		expect(press("Mod-Shift-ArrowUp", "clojure", nested).text).toBe("(let |(c)\n  [x (a\n      b)])");
	});

	test("Clojure gets Cursive's wrap, thread, split, join and kill keys", () => {
		const press1 = (key: string, text: string) => press(key, "clojure", stateOf(text, [clojure])).text;
		expect(press1("Mod-Shift-9", "(a |b)")).toBe("(a (|b))");
		expect(press1("Mod-[", "(a |b)")).toBe("(a [|b])");
		expect(press1("Ctrl-Shift-[", "(a |b)")).toBe("(a {|b})");
		expect(press1("Ctrl-Alt-,", "(f |(g x) b)")).toBe("|(-> (g x) (f b))");
		expect(press1("Ctrl-Alt-,", "(f b |(g x))")).toBe("|(->> (g x) (f b))");
		expect(press1("Ctrl-Alt-.", "(-> x |f)")).toBe("|(f x)");
		expect(press1("Ctrl-Alt-s", "(a |b)")).toBe("(a)| (b)");
		expect(press1("Ctrl-Alt-j", "(a)| (b)")).toBe("(a| b)");
	});

	test("⌃K cuts to the end of the list into the clipboard", async () => {
		const copied: string[] = [];
		const clipboard = { writeText: async (text: string) => void copied.push(text) };
		Object.defineProperty(globalThis.navigator, "clipboard", { value: clipboard, configurable: true });
		try {
			expect(press("Ctrl-k", "clojure", stateOf("(a |b c) d", [clojure]))).toEqual({
				claimed: true,
				text: "(a |) d",
			});
			expect(copied).toEqual(["b c"]);
		} finally {
			Object.defineProperty(globalThis.navigator, "clipboard", { value: undefined, configurable: true });
		}
	});

	test("outside Clojure ⌃K is left to CodeMirror", () => {
		expect(hotkeyBindings("javascript").map((b) => b.mac)).not.toContain("Ctrl-k");
	});

	test("Backspace beside a matched bracket steps over it, and falls through elsewhere", () => {
		expect(press("Backspace", "clojure", stateOf("(a)|", [clojure]))).toEqual({
			claimed: true,
			text: "(a|)",
		});
		expect(press("Backspace", "clojure", stateOf("a)|", [clojure])).claimed).toBe(false);
	});

	test("⇧⌘↑/↓ move a Clojure map entry key with value, and a set element alone", () => {
		const down = (doc: string) => press("Mod-Shift-ArrowDown", "clojure", stateOf(doc, [clojure])).text;
		expect(down("{:a| 1 :b 2}")).toBe("{:b 2 :a| 1}");
		expect(down("{:a 1| :b 2}")).toBe("{:b 2 :a 1|}");
		expect(press("Mod-Shift-ArrowUp", "clojure", stateOf("#:x{:a 1 :b| 2}", [clojure])).text).toBe("#:x{:b| 2 :a 1}");
		expect(down("#{|a b}")).toBe("#{b |a}");
		expect(down("{#_x :a| 1 :b 2}")).toBe("{#_x :b 2 :a| 1}");
		expect(down("(do {:a 1 |#_:b :c 3} (x))")).toBe("(do {:a 1 :c 3 |#_:b} (x))");
	});

	test("⇧⌘↑/↓ move a Clojure map entry with a #_ form between its key and value", () => {
		const press1 = (key: string, doc: string) => press(key, "clojure", stateOf(doc, [clojure])).text;
		expect(press1("Mod-Shift-ArrowDown", "{:a #_x| 1 :b 2}")).toBe("{:b 2 :a #_x| 1}");
		expect(press1("Mod-Shift-ArrowDown", "{:a |#_x 1 :b 2}")).toBe("{:b 2 :a |#_x 1}");
		expect(press1("Mod-Shift-ArrowUp", "{:b 2 :a #_x |1}")).toBe("{:a #_x |1 :b 2}");
	});

	test("⇧⌘↑/↓ move Clojure metadata, a reader tag and a record literal's name with their form", () => {
		const down = (doc: string) => press("Mod-Shift-ArrowDown", "clojure", stateOf(doc, [clojure])).text;
		const up = (doc: string) => press("Mod-Shift-ArrowUp", "clojure", stateOf(doc, [clojure])).text;
		expect(down("(defn ^:pri|vate foo [])")).toBe("(defn [] ^:pri|vate foo)");
		expect(up("(x ^:a fo|o)")).toBe("(^:a fo|o x)");
		expect(down("(x #in|st \"2020\" y)")).toBe("(x y #in|st \"2020\")");
		expect(up("(x #inst \"20|20\" y)")).toBe("(#inst \"20|20\" x y)");
		expect(down("(f #my.R| {:a 1} y)")).toBe("(f y #my.R| {:a 1})");
		expect(up("(f #my.R{:a| 1})")).toBe("(#my.R{:a| 1} f)");
	});

	test("⇧⌘↑/↓ move no key or value of a Clojure map without a value for each key", () => {
		const down = (doc: string) => press("Mod-Shift-ArrowDown", "clojure", stateOf(doc, [clojure])).text;
		expect(down("{:a| 1 :b}")).toBe("{:a| 1 :b}");
		expect(down("x\n{:a| 1\n :b 2")).toBe("x\n{:a| 1\n :b 2");
		expect(down("(do {:a| 1 :b} (x))")).toBe("(do (x) {:a| 1 :b})");
	});
});

describe("editorKeys", () => {
	test("a paste into Clojure re-indents its lines", () => {
		const state = stateOf("(let [x 1]\n  |)", [clojure, editorKeys("clojure")]);
		const next = state.update({
			changes: { from: state.selection.main.head, insert: "(foo a\nb)" },
			userEvent: "input.paste",
		}).state;
		expect(next.doc.toString()).toBe("(let [x 1]\n  (foo a\n       b))");
	});

	test("typing elsewhere is left alone", () => {
		const state = stateOf("(let [x 1]\n  |)", [clojure, editorKeys("clojure")]);
		const next = state.update({ changes: { from: 13, insert: "\nb" }, userEvent: "input.type" }).state;
		expect(next.doc.toString()).toBe("(let [x 1]\n  \nb)");
	});
});

describe("keyLabel", () => {
	test("writes macOS symbols in Apple's order", () => {
		expect(keyLabel("Mod-Shift-k")).toBe("⇧⌘K");
		expect(keyLabel("Alt-Shift-ArrowUp")).toBe("⌥⇧↑");
		expect(keyLabel("Ctrl-Cmd-j")).toBe("⌃⌘J");
		expect(keyLabel("Mod-'")).toBe("⌘'");
	});
});

describe("cheatSheet", () => {
	test("lists the keys for the file's language", () => {
		const keys = (language: string) => cheatSheet(language).map((r) => r.keys);
		expect(keys("text")).toEqual(["⌥⇧↑ / ⌥⇧↓", "⌃J"]);
		expect(keys("python")).toEqual(["⌥⇧↑ / ⌥⇧↓", "⌃J", "⌥↑ / ⌥↓", "⇧⌘↑ / ⇧⌘↓"]);
		expect(keys("clojure")).toEqual([
			"⌥⇧↑ / ⌥⇧↓",
			"⌃J",
			"⌥↑ / ⌥↓",
			"⇧⌘↑ / ⇧⌘↓",
			"⌥← / ⌥→",
			"⇧⌘K / ⇧⌘J",
			"⌃⌘J / ⌃⌘K",
			"⌘'",
			"⌥S",
			"⇧⌘9 / ⌘[ / ⌃⇧[",
			"⌃⌥,",
			"⌃⌥.",
			"⌃⌥S",
			"⌃⌥J",
			"⌃K",
		]);
	});
});

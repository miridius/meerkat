import { describe, expect, test } from "bun:test";
import { history, isolateHistory, redo, undo } from "@codemirror/commands";
import { javascript } from "@codemirror/lang-javascript";
import { LanguageSupport } from "@codemirror/language";
import { EditorSelection, EditorState, type Extension, type Transaction, type TransactionSpec } from "@codemirror/state";
import type { EditorView } from "@codemirror/view";
import { clojureLanguage } from "@nextjournal/lang-clojure";
import { clojureIndent } from "./clojureIndent";
import { cheatSheet, editorKeys, hotkeyBindings, keyLabel } from "./editorKeys";
import { typedQuote } from "./paredit";
import { parsed } from "./syntaxEdit";

const clojure = new LanguageSupport(clojureLanguage, clojureIndent);

function stateOf(marked: string, extensions: Extension[]): EditorState {
	const pos = marked.indexOf("|");
	const doc = marked.replace("|", "");
	const state = EditorState.create({ doc, selection: EditorSelection.cursor(pos), extensions });
	return parsed(state, 5000);
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

	test("a deletion in Clojure keeps the lines below aligned, and one undo takes both back", () => {
		const doc = "(reagent/atom {:a 1\n               :b 2})";
		const state = stateOf(doc, [clojure, editorKeys("clojure"), history()]);
		const next = state.update({ changes: { from: 1, to: 9 }, userEvent: "delete.backward" }).state;
		expect(next.doc.toString()).toBe("(atom {:a 1\n       :b 2})");
		let undone = next;
		undo({ state: next, dispatch: (tr) => (undone = tr.state) });
		expect(undone.doc.toString()).toBe(doc);
	});

	test("a one-line paste, indent or structural key keeps the lines below aligned too", () => {
		const state = stateOf("(f (if x\n       a\n       b))", [clojure, editorKeys("clojure")]);
		const next = state.update({ changes: { from: 3, insert: "g " }, userEvent: "input.paste" }).state;
		expect(next.doc.toString()).toBe("(f g (if x\n         a\n         b))");
		const indented = state.update({ changes: { from: 0, insert: "  " }, userEvent: "input.indent" }).state;
		expect(indented.doc.toString()).toBe("  (f (if x\n         a\n         b))");
		const reindented = state.update({ changes: { from: 0, insert: "  " }, userEvent: "indent" }).state;
		expect(reindented.doc.toString()).toBe("  (f (if x\n         a\n         b))");
		// `c` sat under `b`, whose place the swap gives to `aaaa`'s start.
		const swapped = press("Mod-Shift-ArrowDown", "clojure", stateOf("(f |aaaa b\n        c)", [clojure, editorKeys("clojure")]));
		expect(swapped.text.replace("|", "")).toBe("(f b aaaa\n     c)");
		const spliced = press("Alt-s", "clojure", stateOf("(f (|g) {:a 1\n        :b 2})", [clojure, editorKeys("clojure")]));
		expect(spliced.text).toBe("(f |g {:a 1\n      :b 2})");
	});

	/** `marked` after typing `keys` one by one at its `|`, where `\b`
	 *  deletes the character before. */
	function typeAt(marked: string, keys: string[]): string {
		let state = stateOf(marked, [clojure, editorKeys("clojure")]);
		let at = state.selection.main.head;
		for (const key of keys) {
			const changes = key === "\b" ? { from: at - 1, to: at } : { from: at, insert: key };
			state = state.update({ changes, userEvent: "input.type" }).state;
			at += key === "\b" ? -1 : key.length;
		}
		return state.doc.toString();
	}

	test("typing a string in Clojure moves the lines below with the text above them", () => {
		const keys = ['"', "m", '"', " "];
		for (const [doc, typed, pressed = keys] of [
			["(log/info |{:a 1\n           :b 2})", '(log/info "m" {:a 1\n               :b 2})'],
			// The string being typed runs to the next quote.
			['(log/info |{:a 1\n           :b "x"})', '(log/info "m" {:a 1\n               :b "x"})'],
			['(log/info |{:a "x"\n           :b 2})', '(log/info "m" {:a "x"\n               :b 2})'],
			["(log/info |{:a 1\n           :b 2})", '(log/info "\\n" {:a 1\n                :b 2})', ['"', "\\", "n", '"', " "]],
			["(log/info |{:a 1 ; id\n           :b 2})", '(log/info "m" {:a 1 ; id\n               :b 2})'],
			// An escaped quote typed inside it does not open another.
			["(log/info |{:a 1\n           :b 2})", '(log/info "a\\"b" {:a 1\n                  :b 2})', ['"', "a", "\\", '"', "b", '"', " "]],
			// Backspace on the quote just typed.
			["(log/info |{:a 1\n           :b 2})", "(log/info {:a 1\n           :b 2})", ['"', "\b"]],
		] as [string, string, string[]?][]) {
			expect(typeAt(doc, pressed)).toBe(typed);
		}
	});

	/** The state after `steps` from `doc`: each types its text at its
	 *  position as a new undo step, or, marked "join", in the step before;
	 *  or undoes or redoes one. */
	function replay(doc: string, steps: ([number, string, "join"?] | "undo" | "redo")[]): EditorState {
		let state = stateOf(doc, [clojure, editorKeys("clojure"), history()]);
		const dispatch = (tr: Transaction) => {
			state = tr.state;
		};
		for (const step of steps) {
			if (step === "undo") undo({ state, dispatch });
			else if (step === "redo") redo({ state, dispatch });
			else {
				const [from, insert, join] = step;
				state = state.update({
					changes: { from, insert },
					userEvent: "input.type",
					annotations: join ? [] : isolateHistory.of("before"),
				}).state;
			}
		}
		return state;
	}

	test("undo and redo in Clojure bring back a string being typed", () => {
		const doc = "(log/info {:a 1\n           :b 2})";
		const typed = (text: string) => `(log/info ${text} {:a 1\n${" ".repeat(12 + text.length)}:b 2})`;
		const close = (at: number): [number, string][] => [
			[at, '"'],
			[at + 1, " "],
		];
		// Undo a letter, the closing quote, or the opening quote and redo it.
		const letter = replay(doc, [[10, '"'], [11, "a"], [12, "b"], "undo", [12, "c"], ...close(13)]);
		expect(letter.doc.toString()).toBe(typed('"ac"'));
		const closing = replay(doc, [[10, '"'], [11, "a"], [12, '"'], "undo", [12, "c"], ...close(13)]);
		expect(closing.doc.toString()).toBe(typed('"ac"'));
		const opening = replay(doc, [[10, '"'], "undo", "redo", [11, "a"], ...close(12)]);
		expect(opening.doc.toString()).toBe(typed('"a"'));
		// One undo step that ends the string and types another.
		const merged = replay(doc, [[10, '"'], [11, "a"], [12, '"'], [13, " ", "join"], [14, '"', "join"], "undo"]);
		expect(merged.field(typedQuote)).toBe(10);
	});

	test("deleting the opening quote of a string being typed in Clojure ends it", () => {
		const state = replay("(log/info {:a 1\n           :b 2})", [[10, '"']]);
		expect(state.update({ changes: { from: 10, to: 11 } }).state.field(typedQuote)).toBeNull();
	});

	test("an edit outside a string being typed in Clojure ends it", () => {
		const doc = "(log/info {:a 1\n           :b 2})";
		expect(replay(doc, [[10, '"']]).field(typedQuote)).toBe(10);
		expect(replay(doc, [[10, '"'], [1, "x"]]).field(typedQuote)).toBeNull();
		expect(replay(doc, [[10, '"'], [doc.length, "x"]]).field(typedQuote)).toBeNull();
	});

	test("a string being typed in Clojure is read as closed right after the edit", () => {
		const doc = "(str x y z w v u t s)\n(defn g []\n  (let [a 1]\n    (foo a\n         b)))";
		expect(typeAt(doc.replace("x", "|x"), ['"', "a"])).toBe(doc.replace("x", '"ax'));
	});
});

describe("keyLabel", () => {
	test("writes macOS symbols in Apple's order", () => {
		expect(keyLabel("Mod-Shift-k")).toBe("⇧⌘K");
		expect(keyLabel("Alt-Shift-ArrowUp")).toBe("⌥⇧↑");
		expect(keyLabel("Ctrl-Cmd-j")).toBe("⌃⌘J");
		expect(keyLabel("Mod-'")).toBe("⌘'");
	});

	test("writes Shift as the symbol it types where the key has one", () => {
		expect(keyLabel("Mod-Shift-9")).toBe("⌘(");
		expect(keyLabel("Ctrl-Shift-[")).toBe("⌃{");
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
			"⌘( / ⌘[ / ⌃{",
			"⌃⌥, / ⌃⌥.",
			"⌃⌥S / ⌃⌥J",
			"⌃K",
		]);
	});
});

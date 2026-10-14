import { moveLineDown, moveLineUp } from "@codemirror/commands";
import { type EditorState, type Extension, EditorState as State, type TransactionSpec } from "@codemirror/state";
import { type Command, type KeyBinding, keymap } from "@codemirror/view";
import {
	barfBackward,
	barfForward,
	bracketTyping,
	deleteGuarded,
	moveByForm,
	raise,
	reindent,
	slurpBackward,
	slurpForward,
	splice,
	tightInClojure,
} from "./paredit.js";
import { expandSelection, joinLines, moveNode, selectionHistory, shrinkSelection } from "./syntaxEdit.js";

/** The suggestion editor's IDE-style hotkeys (Cursive's macOS keymap),
 *  and the cheat sheet that lists them. See "Editor hotkeys" in
 *  docs/features/inline-comments.md. */

/** Which files a key works in: every file, files whose language has a
 *  syntax grammar, or Clojure files. */
export type Scope = "all" | "grammar" | "clojure";

/** A key in CodeMirror's notation: the same everywhere, or one for
 *  macOS and one for other systems. */
type Key = string | { mac: string; other: string };

type Edit = (state: EditorState) => TransactionSpec | null;

interface Hotkey {
	scope: Scope;
	keys: Key[];
	does: string;
	/** The command for each key, given whether the file is Clojure. */
	run: ((clojure: boolean) => Command)[];
	/** Keys that run the first key's command without being listed. */
	alias?: Key[];
}

/** A command that dispatches `edit`'s transaction. It claims the key
 *  even when `edit` does nothing, so CodeMirror's own binding for the key
 *  never runs in the files the key is for. */
function claim(edit: Edit): Command {
	return (view) => {
		const spec = edit(view.state);
		if (spec) view.dispatch(spec);
		return true;
	};
}

/** `edit`, with the lines it changes re-indented in Clojure. */
function indented(edit: Edit, clojure: boolean): Edit {
	return clojure
		? (state) => {
				const spec = edit(state);
				return spec && reindent(state, spec);
			}
		: edit;
}

export const HOTKEYS: Hotkey[] = [
	{
		scope: "all",
		keys: ["Alt-Shift-ArrowUp", "Alt-Shift-ArrowDown"],
		does: "Move the line up / down",
		run: [() => moveLineUp, () => moveLineDown],
	},
	{
		scope: "all",
		keys: [{ mac: "Ctrl-j", other: "Alt-j" }],
		does: "Join the next line, or the selected lines",
		run: [(clojure) => claim((state) => joinLines(state, clojure ? tightInClojure : undefined))],
	},
	{
		scope: "grammar",
		keys: ["Alt-ArrowUp", "Alt-ArrowDown"],
		does: "Expand / shrink the selection",
		run: [() => claim(expandSelection), () => claim(shrinkSelection)],
	},
	{
		scope: "grammar",
		keys: ["Mod-Shift-ArrowUp", "Mod-Shift-ArrowDown"],
		does: "Move the statement, element or argument up / down",
		run: [
			(clojure) => claim(indented((state) => moveNode(state, -1), clojure)),
			(clojure) => claim(indented((state) => moveNode(state, 1), clojure)),
		],
	},
	{
		scope: "clojure",
		keys: ["Alt-ArrowLeft", "Alt-ArrowRight"],
		does: "Move back / forward one form",
		run: [() => claim((state) => moveByForm(state, -1)), () => claim((state) => moveByForm(state, 1))],
	},
	{
		scope: "clojure",
		keys: ["Mod-Shift-k", "Mod-Shift-j"],
		does: "Slurp / barf forward",
		run: [() => claim(slurpForward), () => claim(barfForward)],
	},
	{
		scope: "clojure",
		keys: [
			{ mac: "Ctrl-Cmd-j", other: "Ctrl-Alt-j" },
			{ mac: "Ctrl-Cmd-k", other: "Ctrl-Alt-k" },
		],
		does: "Slurp / barf backward",
		run: [() => claim(slurpBackward), () => claim(barfBackward)],
	},
	{
		scope: "clojure",
		keys: ["Mod-'"],
		does: "Raise the form, replacing its parent",
		run: [() => claim(raise)],
	},
	{
		scope: "clojure",
		keys: ["Alt-s"],
		// Option+S types ß on a Mac, and CodeMirror names the key so.
		alias: ["Alt-ß"],
		does: "Splice: remove the enclosing brackets",
		run: [() => claim(splice)],
	},
];

/** The scopes that apply to a file in `language`. */
export function scopesFor(language: string, hasGrammar: boolean): Scope[] {
	if (language === "clojure") return ["all", "grammar", "clojure"];
	return hasGrammar ? ["all", "grammar"] : ["all"];
}

function binding(key: Key, run: Command): KeyBinding {
	return typeof key === "string"
		? { key, run, preventDefault: true }
		: { key: key.other, mac: key.mac, run, preventDefault: true };
}

/** A command that runs `edit`, letting the key fall through to
 *  CodeMirror when it does nothing. */
function claimIf(edit: Edit): Command {
	return (view) => {
		const spec = edit(view.state);
		if (!spec) return false;
		view.dispatch(spec);
		return true;
	};
}

/** Re-indent the lines a paste brings in. */
const reindentPaste = State.transactionFilter.of((tr) => {
	if (!tr.docChanged || !tr.isUserEvent("input.paste")) return tr;
	const spec = reindent(tr.startState, { changes: tr.changes, selection: tr.selection, userEvent: "input.paste" });
	return spec.changes === tr.changes ? tr : spec;
});

/** The key bindings for a file in `language`; `hasGrammar` when its
 *  language has a syntax grammar. */
export function hotkeyBindings(language: string, hasGrammar: boolean): KeyBinding[] {
	const scopes = scopesFor(language, hasGrammar);
	const clojure = language === "clojure";
	const bindings: KeyBinding[] = [];
	for (const hotkey of HOTKEYS) {
		if (!scopes.includes(hotkey.scope)) continue;
		const commands = hotkey.run.map((run) => run(clojure));
		bindings.push(...hotkey.keys.map((key, i) => binding(key, commands[i])));
		for (const alias of hotkey.alias ?? []) bindings.push(binding(alias, commands[0]));
	}
	// Without a grammar, ⌥↑/⌥↓ still do not move lines: that moved to
	// ⌥⇧↑/⌥⇧↓.
	if (!scopes.includes("grammar")) {
		for (const key of ["Alt-ArrowUp", "Alt-ArrowDown"]) bindings.push({ key, run: () => true });
	}
	if (clojure) {
		bindings.push(
			{ key: "Backspace", run: claimIf((state) => deleteGuarded(state, -1)) },
			{ key: "Delete", run: claimIf((state) => deleteGuarded(state, 1)) },
		);
	}
	return bindings;
}

/** The hotkeys, and in Clojure the structural typing, for a file in
 *  `language`; `hasGrammar` when its language has a syntax grammar. */
export function editorKeys(language: string, hasGrammar: boolean): Extension {
	const extensions: Extension[] = [selectionHistory, keymap.of(hotkeyBindings(language, hasGrammar))];
	if (language === "clojure") extensions.push(bracketTyping, reindentPaste);
	return extensions;
}

const MAC_SYMBOLS: [string, string][] = [
	["Ctrl", "⌃"],
	["Alt", "⌥"],
	["Shift", "⇧"],
	["Cmd", "⌘"],
	["Mod", "⌘"],
];
const OTHER_NAMES: [string, string][] = [
	["Ctrl", "Ctrl"],
	["Mod", "Ctrl"],
	["Alt", "Alt"],
	["Shift", "Shift"],
];
const KEY_NAMES: Record<string, string> = { ArrowUp: "↑", ArrowDown: "↓", ArrowLeft: "←", ArrowRight: "→" };

/** `key` as a person reads it: ⌥⇧↑ on macOS, Alt+Shift+↑ elsewhere.
 *  macOS writes modifiers in the order Control, Option, Shift, Command. */
export function keyLabel(key: Key, mac: boolean): string {
	const spec = typeof key === "string" ? key : mac ? key.mac : key.other;
	const parts = spec.split("-");
	const name = parts.pop() as string;
	const shown = KEY_NAMES[name] ?? name.toUpperCase();
	const mods = (mac ? MAC_SYMBOLS : OTHER_NAMES).filter(([m]) => parts.includes(m)).map(([, label]) => label);
	return mac ? mods.join("") + shown : [...mods, shown].join("+");
}

/** The cheat sheet's rows for a file in `language`. */
export function cheatSheet(language: string, hasGrammar: boolean, mac: boolean): { keys: string; does: string }[] {
	const scopes = scopesFor(language, hasGrammar);
	return HOTKEYS.filter((h) => scopes.includes(h.scope)).map((h) => ({
		keys: h.keys.map((k) => keyLabel(k, mac)).join(" / "),
		does: h.does,
	}));
}

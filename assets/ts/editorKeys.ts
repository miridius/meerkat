import { moveLineDown, moveLineUp } from "@codemirror/commands";
import { type EditorState, type Extension, EditorState as State, type TransactionSpec } from "@codemirror/state";
import { type Command, type KeyBinding, keymap } from "@codemirror/view";
import { SUPPORTED_LANGUAGES } from "./cmLang.js";
import {
	barfBackward,
	barfForward,
	bracketTyping,
	clojureItems,
	deleteGuarded,
	joinForms,
	kill,
	moveByForm,
	raise,
	reindent,
	slurpBackward,
	slurpForward,
	splice,
	split,
	thread,
	tightInClojure,
	unthread,
	wrap,
} from "./paredit.js";
import { expandSelection, joinLines, moveNode, selectionHistory, shrinkSelection } from "./syntaxEdit.js";

/** The suggestion editor's IDE-style hotkeys (Cursive's macOS keymap),
 *  bound on macOS only, and the cheat sheet that lists them. See "Editor
 *  hotkeys" in docs/features/inline-comments.md. */

/** Which files a key works in: every file, files whose language has a
 *  syntax grammar, or Clojure files. */
export type Scope = "all" | "grammar" | "clojure";

type Edit = (state: EditorState) => TransactionSpec | null;

interface Hotkey {
	scope: Scope;
	/** Each key, in CodeMirror's notation. */
	keys: string[];
	does: string;
	/** The command for each key, given whether the file is Clojure. */
	run: ((clojure: boolean) => Command)[];
	/** Keys that run the first key's command without being listed. */
	alias?: string[];
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

/** Cursive's Kill: cut what `kill` deletes to the clipboard. */
const cutKill: Command = (view) => {
	const killed = kill(view.state);
	if (!killed) return true;
	// The clipboard is missing outside a secure context; the kill still deletes.
	navigator.clipboard?.writeText(killed.text).catch((error) => console.warn("meerkat: kill could not copy", error));
	view.dispatch(killed.spec);
	return true;
};

export const HOTKEYS: Hotkey[] = [
	{
		scope: "all",
		keys: ["Alt-Shift-ArrowUp", "Alt-Shift-ArrowDown"],
		does: "Move the line up / down",
		run: [() => moveLineUp, () => moveLineDown],
	},
	{
		scope: "all",
		keys: ["Ctrl-j"],
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
			(clojure) => claim(indented((state) => moveNode(state, -1, clojure ? clojureItems : undefined), clojure)),
			(clojure) => claim(indented((state) => moveNode(state, 1, clojure ? clojureItems : undefined), clojure)),
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
		keys: ["Ctrl-Cmd-j", "Ctrl-Cmd-k"],
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
	{
		scope: "clojure",
		// Cursive's ⇧⌘[ is Chrome's previous tab, which pages cannot take.
		keys: ["Mod-Shift-9", "Mod-[", "Ctrl-Shift-["],
		does: "Wrap the form in ( ) / [ ] / { }",
		run: (["(", "[", "{"] as const).map((open) => () => claim((state) => wrap(state, open))),
	},
	{
		scope: "clojure",
		keys: ["Ctrl-Alt-,", "Ctrl-Alt-Shift-,"],
		does: "Thread the list one step with -> / ->>",
		run: [() => claim((state) => thread(state, "->")), () => claim((state) => thread(state, "->>"))],
	},
	{
		scope: "clojure",
		keys: ["Ctrl-Alt-."],
		does: "Unthread one step of the enclosing -> or ->>",
		run: [() => claim(unthread)],
	},
	{
		scope: "clojure",
		keys: ["Ctrl-Alt-s"],
		does: "Split the list or string in two at the caret",
		run: [() => claim(split)],
	},
	{
		scope: "clojure",
		keys: ["Ctrl-Alt-j"],
		does: "Join the forms either side of the caret",
		run: [() => claim(joinForms)],
	},
	{
		scope: "clojure",
		keys: ["Ctrl-k"],
		does: "Kill: cut to the end of the line or the enclosing form",
		run: [() => cutKill],
	},
];

/** The scopes that apply to a file in `language`. */
export function scopesFor(language: string): Scope[] {
	if (language === "clojure") return ["all", "grammar", "clojure"];
	return SUPPORTED_LANGUAGES.includes(language) ? ["all", "grammar"] : ["all"];
}

/** A binding of `key` on macOS only: elsewhere the key keeps
 *  CodeMirror's own binding. */
function binding(key: string, run: Command): KeyBinding {
	return { mac: key, run, preventDefault: true };
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

/** The key bindings for a file in `language`. */
export function hotkeyBindings(language: string): KeyBinding[] {
	const scopes = scopesFor(language);
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
		for (const key of ["Alt-ArrowUp", "Alt-ArrowDown"]) bindings.push(binding(key, () => true));
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
 *  `language`. */
export function editorKeys(language: string): Extension {
	const extensions: Extension[] = [selectionHistory, keymap.of(hotkeyBindings(language))];
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
const KEY_NAMES: Record<string, string> = { ArrowUp: "↑", ArrowDown: "↓", ArrowLeft: "←", ArrowRight: "→" };

/** `key` as a person reads it on macOS: ⌥⇧↑. macOS writes modifiers in
 *  the order Control, Option, Shift, Command. */
export function keyLabel(key: string): string {
	const parts = key.split("-");
	const name = parts.pop() as string;
	const shown = KEY_NAMES[name] ?? name.toUpperCase();
	return MAC_SYMBOLS.filter(([m]) => parts.includes(m)).map(([, symbol]) => symbol).join("") + shown;
}

/** The cheat sheet's rows for a file in `language`. */
export function cheatSheet(language: string): { keys: string; does: string }[] {
	const scopes = scopesFor(language);
	return HOTKEYS.filter((h) => scopes.includes(h.scope)).map((h) => ({
		keys: h.keys.map(keyLabel).join(" / "),
		does: h.does,
	}));
}

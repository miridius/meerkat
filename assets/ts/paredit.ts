import { indentRange, syntaxTree } from "@codemirror/language";
import {
	type ChangeSpec,
	EditorSelection,
	type EditorState,
	findClusterBreak,
	type SelectionRange,
	type TransactionSpec,
} from "@codemirror/state";
import { EditorView } from "@codemirror/view";

/** Structural editing for Clojure, in the style of Cursive's paredit,
 *  over the Lezer tree of `@nextjournal/lang-clojure`. Each command takes
 *  a state and returns the transaction to dispatch, or null when it does
 *  nothing there. Commands leave a collection the editor's lines cut off
 *  from its closer alone, as they cannot see where it ends. */

type SyntaxNode = ReturnType<typeof syntaxTree>["topNode"];

const CLOSERS: Record<string, string> = { List: ")", Vector: "]", Map: "}" };
const PAIRS: Record<string, string> = { "(": ")", "[": "]", "{": "}" };
const BRACKETS = new Set(["(", ")", "[", "]", "{", "}"]);
/** Forms whose prefix is part of the opener: `#{`, `#(`, `#?(`, `#:a{`. */
const PREFIXED = new Set(["Set", "AnonymousFunction", "ReaderConditional", "NamespacedMap"]);

function isColl(node: SyntaxNode): boolean {
	return node.name in CLOSERS;
}

/** The closing bracket of `coll`, or null when the text lacks it. */
function closerOf(coll: SyntaxNode): SyntaxNode | null {
	const last = coll.lastChild;
	return last && last.name === CLOSERS[coll.name] ? last : null;
}

/** The forms in a collection or the program: comments, brackets and
 *  stray tokens left out; `#_` forms in. */
function forms(parent: SyntaxNode): SyntaxNode[] {
	const out: SyntaxNode[] = [];
	for (let child = parent.firstChild; child; child = child.nextSibling) {
		if (!BRACKETS.has(child.name) && child.name !== "LineComment" && !child.type.isError) out.push(child);
	}
	return out;
}

/** The form that stands for `node` among its parent's forms: `node`
 *  itself, or the quote, metadata or other prefix form wrapping it. */
function element(node: SyntaxNode): SyntaxNode {
	let el = node;
	while (el.parent?.parent && !isColl(el.parent)) el = el.parent;
	return el;
}

/** Where `coll`'s opening bracket starts, with a `#` prefix it has. */
function openStart(coll: SyntaxNode): number {
	return coll.parent && PREFIXED.has(coll.parent.name) ? coll.parent.from : coll.from;
}

/** The innermost collection whose brackets hold `pos`, or null at the
 *  top level. A collection with no closer holds everything after its
 *  opener. */
function enclosing(state: EditorState, pos: number): SyntaxNode | null {
	for (let node: SyntaxNode | null = syntaxTree(state).resolveInner(pos, -1); node; node = node.parent) {
		if (!isColl(node) || !node.firstChild || pos < node.firstChild.to) continue;
		const closer = closerOf(node);
		if (!closer || pos <= closer.from) return node;
	}
	return null;
}

/** The form after `el` among its parent's forms, or before it. */
function sibling(el: SyntaxNode, dir: -1 | 1): SyntaxNode | null {
	const parent = el.parent;
	if (!parent) return null;
	const all = forms(parent);
	const at = all.findIndex((f) => f.from === el.from && f.to === el.to);
	return all[at + dir] ?? null;
}

/** The changes, and the selection mapped through them, for each range's
 *  head: `edit` returns the changes for one caret, or null. Lines the
 *  changes reach re-indent. Null when no range changes. */
function edit(
	state: EditorState,
	userEvent: string,
	command: (pos: number) => { changes: ChangeSpec[]; cursor?: number; assoc?: -1 | 1 } | null,
): TransactionSpec | null {
	let changed = false;
	const spec = state.changeByRange((range: SelectionRange) => {
		const result = command(range.head);
		if (!result) return { range };
		changed = true;
		const set = state.changes(result.changes);
		return {
			changes: set,
			range: result.cursor === undefined ? range.map(set, result.assoc) : EditorSelection.cursor(result.cursor),
		};
	});
	if (!changed) return null;
	return reindent(state, { ...spec, scrollIntoView: true, userEvent });
}

/** `spec` with the lines its changes reach re-indented, from the first
 *  line whose indentation a change can affect to the last line a change
 *  touches. */
export function reindent(state: EditorState, spec: TransactionSpec): TransactionSpec {
	// Unfiltered, so a filter that calls this does not call itself.
	const tr = state.update(spec, { filter: false });
	let from = -1;
	let to = -1;
	tr.changes.iterChangedRanges((_fromA, _toA, fromB, toB) => {
		if (from < 0 || fromB < from) from = fromB;
		if (toB > to) to = toB;
	});
	if (from < 0) return spec;
	const doc = tr.state.doc;
	// An edit after a line's first character leaves that line's own
	// indentation alone.
	const line = doc.lineAt(from);
	if (doc.sliceString(line.from, from).trim() !== "") {
		if (line.to >= to) return spec;
		from = line.to + 1;
	}
	const indent = indentRange(tr.state, from, to);
	if (indent.empty) return spec;
	return {
		changes: tr.changes.compose(indent),
		selection: tr.newSelection.map(indent),
		scrollIntoView: true,
		userEvent: spec.userEvent,
	};
}

/** Pull the form after the caret's collection into it; past the last
 *  form, the form after the nearest enclosing collection that has one. */
export function slurpForward(state: EditorState): TransactionSpec | null {
	return edit(state, "edit.slurp", (pos) => {
		for (let coll = enclosing(state, pos); coll; coll = enclosing(state, element(coll).from)) {
			const closer = closerOf(coll);
			if (!closer) return null;
			const el = element(coll);
			const target = sibling(el, 1);
			if (!target) continue;
			const gap = state.doc.sliceString(closer.to, target.from);
			const empty = forms(coll).length === 0;
			const changes: ChangeSpec[] = [{ from: target.to, insert: closer.name }];
			if (empty && gap.trim() === "") changes.push({ from: closer.from, to: target.from });
			else changes.push({ from: closer.from, to: closer.to, insert: gap === "" ? " " : "" });
			return { changes };
		}
		return null;
	});
}

/** Push the last form of the caret's collection out after it. */
export function barfForward(state: EditorState): TransactionSpec | null {
	return edit(state, "edit.barf", (pos) => {
		const coll = enclosing(state, pos);
		const closer = coll && closerOf(coll);
		if (!coll || !closer || !coll.firstChild) return null;
		const all = forms(coll);
		if (all.length === 0) return null;
		const at = all.length > 1 ? all[all.length - 2].to : coll.firstChild.to;
		const spaced = /\s/.test(state.doc.sliceString(at, at + 1));
		return {
			changes: [
				{ from: at, insert: spaced ? closer.name : `${closer.name} ` },
				{ from: closer.from, to: closer.to },
			],
		};
	});
}

/** Pull the form before the caret's collection into it; before the first
 *  form, the form before the nearest enclosing collection that has one. */
export function slurpBackward(state: EditorState): TransactionSpec | null {
	return edit(state, "edit.slurp", (pos) => {
		for (let coll = enclosing(state, pos); coll; coll = enclosing(state, element(coll).from)) {
			if (!closerOf(coll) || !coll.firstChild) return null;
			const el = element(coll);
			const target = sibling(el, -1);
			if (!target) continue;
			const opener = state.doc.sliceString(el.from, coll.firstChild.to);
			const gap = state.doc.sliceString(target.to, el.from);
			const empty = forms(coll).length === 0;
			const changes: ChangeSpec[] = [{ from: target.from, insert: opener }];
			if (empty && gap.trim() === "") changes.push({ from: target.to, to: coll.firstChild.to });
			else changes.push({ from: el.from, to: coll.firstChild.to, insert: gap === "" ? " " : "" });
			return { changes };
		}
		return null;
	});
}

/** Push the first form of the caret's collection out before it. */
export function barfBackward(state: EditorState): TransactionSpec | null {
	return edit(state, "edit.barf", (pos) => {
		const coll = enclosing(state, pos);
		const closer = coll && closerOf(coll);
		if (!coll || !closer || !coll.firstChild) return null;
		const all = forms(coll);
		if (all.length === 0) return null;
		const el = element(coll);
		const opener = state.doc.sliceString(el.from, coll.firstChild.to);
		const lead = state.doc.sliceString(coll.firstChild.to, all[0].from);
		const removeTo = lead.trim() === "" ? all[0].from : coll.firstChild.to;
		const changes: ChangeSpec[] = [{ from: el.from, to: removeTo }];
		if (all.length > 1) changes.push({ from: all[1].from, insert: opener });
		else changes.push({ from: closer.from, insert: ` ${opener}` });
		// A caret at the new opener stays inside the list.
		return { changes, assoc: 1 };
	});
}

/** Remove the brackets of the caret's collection, keeping its forms. */
export function splice(state: EditorState): TransactionSpec | null {
	return edit(state, "edit.splice", (pos) => {
		const coll = enclosing(state, pos);
		const closer = coll && closerOf(coll);
		if (!coll || !closer || !coll.firstChild) return null;
		return {
			changes: [
				{ from: openStart(coll), to: coll.firstChild.to },
				{ from: closer.from, to: closer.to },
			],
		};
	});
}

/** Replace the caret's collection with the form at the caret: the one
 *  the caret touches, or else the next one. */
export function raise(state: EditorState): TransactionSpec | null {
	return edit(state, "edit.raise", (pos) => {
		const coll = enclosing(state, pos);
		if (!coll || !closerOf(coll)) return null;
		const all = forms(coll);
		const form = all.find((f) => f.from <= pos && pos <= f.to) ?? all.find((f) => f.from >= pos);
		if (!form) return null;
		const el = element(coll);
		const offset = Math.max(0, pos - form.from);
		return {
			changes: [{ from: el.from, to: el.to, insert: state.doc.sliceString(form.from, form.to) }],
			cursor: el.from + offset,
		};
	});
}

/** Where moving one form from `pos` lands: past the next form, or out
 *  past the closer after the last one (`dir` 1); before the previous
 *  form, or out before the opener ahead of the first one (`dir` -1). */
export function formStep(state: EditorState, pos: number, dir: -1 | 1): number {
	const coll = enclosing(state, pos);
	const all = forms(coll ?? syntaxTree(state).topNode);
	if (dir > 0) {
		const next = all.find((f) => f.to > pos);
		if (next) return next.to;
		const closer = coll && closerOf(coll);
		return closer ? closer.to : pos;
	}
	const prev = all.findLast((f) => f.from < pos);
	if (prev) return prev.from;
	return coll ? element(coll).from : pos;
}

/** Move each caret one form back (`dir` -1) or forward, as Cursive's
 *  Move Backward and Move Forward do; a selection collapses from its
 *  head. */
export function moveByForm(state: EditorState, dir: -1 | 1): TransactionSpec {
	return {
		selection: EditorSelection.create(
			state.selection.ranges.map((r) => EditorSelection.cursor(formStep(state, r.head, dir))),
			state.selection.mainIndex,
		),
		scrollIntoView: true,
		userEvent: "select",
	};
}

/** The bracket token spanning `from..from+1`, when it is code (not in a
 *  string or comment), with whether its partner exists. */
function bracketAt(state: EditorState, from: number): { node: SyntaxNode; matched: boolean } | null {
	if (from < 0 || from >= state.doc.length) return null;
	const node = syntaxTree(state).resolveInner(from, 1);
	if (node.from !== from || node.to !== from + 1 || !BRACKETS.has(node.name)) return null;
	const parent = node.parent;
	if (!parent || !isColl(parent)) return { node, matched: false };
	const closer = closerOf(parent);
	return { node, matched: node.name in PAIRS ? closer !== null : closer?.from === node.from };
}

/** Backspace (`dir` -1) or Delete (`dir` 1) at a caret beside a bracket
 *  of a matched pair: steps over it, or deletes the pair when the caret
 *  sits inside it and it is empty. Null when no caret is beside one, so
 *  the editor's own deletion runs; a selection always deletes. */
export function deleteGuarded(state: EditorState, dir: -1 | 1): TransactionSpec | null {
	if (state.selection.ranges.some((r) => !r.empty)) return null;
	let guarded = false;
	const spec = state.changeByRange((range) => {
		const pos = range.head;
		const at = dir < 0 ? pos - 1 : pos;
		const bracket = bracketAt(state, at);
		if (!bracket?.matched) {
			const line = state.doc.lineAt(pos);
			const atEdge = dir < 0 ? pos === line.from : pos === line.to;
			const end = atEdge
				? Math.min(state.doc.length, Math.max(0, pos + dir))
				: line.from + findClusterBreak(line.text, pos - line.from, dir > 0);
			const set = state.changes({ from: Math.min(pos, end), to: Math.max(pos, end) });
			return { changes: set, range: EditorSelection.cursor(Math.min(pos, end)) };
		}
		guarded = true;
		const parent = bracket.node.parent as SyntaxNode;
		const opener = parent.firstChild as SyntaxNode;
		const closer = closerOf(parent) as SyntaxNode;
		if (opener.to === pos && closer.from === pos) {
			const set = state.changes({ from: opener.from, to: closer.to });
			return { changes: set, range: EditorSelection.cursor(opener.from) };
		}
		return { range: EditorSelection.cursor(pos + dir) };
	});
	if (!guarded) return null;
	return { ...spec, scrollIntoView: true, userEvent: dir < 0 ? "delete.backward" : "delete.forward" };
}

/** Whether `pos` sits in a string, a comment or a character literal,
 *  where brackets are text. */
function inText(state: EditorState, pos: number): boolean {
	for (let node: SyntaxNode | null = syntaxTree(state).resolveInner(pos, -1); node; node = node.parent) {
		if (node.name === "String" || node.name === "RegExp") return node.from < pos && pos < node.to;
		if (node.name === "LineComment") return node.from < pos;
		if (node.name === "Character") return node.from < pos && pos < node.to;
	}
	return state.doc.sliceString(pos - 1, pos) === "\\";
}

/** Typing `text`: an opener inserts its closer too, around a selection if
 *  there is one; a closer before the same matched closer steps over it.
 *  Null, so the editor types `text` itself, for anything else and for
 *  brackets in strings and comments. */
export function typeBracket(state: EditorState, text: string): TransactionSpec | null {
	if (!(text in PAIRS || Object.values(PAIRS).includes(text))) return null;
	const ranges = state.selection.ranges;
	if (ranges.some((r) => inText(state, r.from))) return null;
	if (text in PAIRS) {
		return {
			...state.changeByRange((range) => ({
				changes: [
					{ from: range.from, insert: text },
					{ from: range.to, insert: PAIRS[text] },
				],
				range: range.empty
					? EditorSelection.cursor(range.from + 1)
					: EditorSelection.range(range.from + 1, range.to + 1),
			})),
			scrollIntoView: true,
			userEvent: "input.type",
		};
	}
	const stepsOver = (r: SelectionRange) => {
		const bracket = bracketAt(state, r.head);
		return r.empty && bracket?.matched === true && bracket.node.name === text;
	};
	if (!ranges.every(stepsOver)) return null;
	return {
		selection: EditorSelection.create(
			ranges.map((r) => EditorSelection.cursor(r.head + 1)),
			state.selection.mainIndex,
		),
		scrollIntoView: true,
		userEvent: "input.type",
	};
}

/** Structural typing of brackets; see `typeBracket`. */
export const bracketTyping = EditorView.inputHandler.of((view, _from, _to, text) => {
	if (view.composing) return false;
	const spec = typeBracket(view.state, text);
	if (spec) view.dispatch(spec);
	return spec !== null;
});

/** Whether no space belongs between `before` and `after` when lines
 *  join: none after an opener or before a closer. */
export function tightInClojure(before: string, after: string): boolean {
	return before in PAIRS || Object.values(PAIRS).includes(after);
}

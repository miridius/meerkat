import { indentRange, syntaxTree } from "@codemirror/language";
import {
	type ChangeSet,
	type ChangeSpec,
	EditorSelection,
	type EditorState,
	findClusterBreak,
	type SelectionRange,
	type TransactionSpec,
} from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import {
	BRACKETS,
	closerOf,
	forms,
	holder,
	holds,
	inString,
	isColl,
	type SyntaxNode,
} from "./clojureTree.js";
import { type Entries, type Span, whole } from "./syntaxEdit.js";

/** Structural editing for Clojure, in the style of Cursive's paredit,
 *  over the Lezer tree of `@nextjournal/lang-clojure`. Each editing
 *  command returns the transaction to dispatch, or null when it does
 *  nothing there. Commands leave a collection the editor's lines cut off
 *  from its closer alone, as they cannot see where it ends. */

const PAIRS: Record<string, string> = { "(": ")", "[": "]", "{": "}" };
/** Forms whose prefix is part of the opener: `#{`, `#(`, `#?(`, `#?@(`,
 *  `#:a{`. */
const PREFIXED = new Set(["Set", "AnonymousFunction", "ReaderConditional", "NamespacedMap"]);
/** Forms of a prefix and the form it applies to: `^:private foo`,
 *  `#inst "…"`, `#my.Rec{…}`. */
const PREFIX_CONTAINERS = new Set(["Meta", "TaggedLiteral", "ConstructorCall"]);
/** Forms whose prefix takes only certain forms: `#my.Rec{…}`, `#"…"`,
 *  `#'foo`. */
const NARROW_PREFIXED = new Set(["ConstructorCall", "RegExp", "Var"]);

/** `node` with the prefixes that apply to it: each form wrapping it that
 *  ends with it, such as a quote, a tag or metadata, but not the
 *  metadata `node` is the map of, nor a form a `#_` form sits in before
 *  that form's own. */
function element(node: SyntaxNode): SyntaxNode {
	let el = node;
	while (el.parent?.parent && !isColl(el.parent) && el.parent.to === el.to) el = el.parent;
	return el;
}

/** Whether `coll` sits in another form's prefix, as a metadata map does
 *  or a list a `#_` hides there. The structural keys leave such a list
 *  alone: what they move out would take that prefix with it. */
function inPrefix(coll: SyntaxNode): boolean {
	const el = element(coll);
	return !!el.parent?.parent && !isColl(el.parent);
}

/** Where `coll`'s opening bracket starts, with the prefix that is part
 *  of its opener (`#`, `#?`, `#?@`, `#:ns`, `#::ns`). */
function openStart(coll: SyntaxNode): number {
	const parent = holder(coll);
	return parent && PREFIXED.has(parent.name) ? parent.from : coll.from;
}

/** The innermost collection whose brackets hold `pos`, or null at the
 *  top level. */
function enclosing(state: EditorState, pos: number): SyntaxNode | null {
	for (let node: SyntaxNode | null = syntaxTree(state).resolveInner(pos, -1); node; node = node.parent) {
		if (!isColl(node) || !node.firstChild || pos < node.firstChild.to) continue;
		if (holds(node, pos)) return node;
	}
	return null;
}

/** The form after `el` among its parent's forms, or before it. Null past
 *  a bracket, stray or not, and when the form is not whole. */
function sibling(el: SyntaxNode, dir: -1 | 1): SyntaxNode | null {
	for (let sib = dir > 0 ? el.nextSibling : el.prevSibling; sib; sib = dir > 0 ? sib.nextSibling : sib.prevSibling) {
		if (sib.name === "LineComment") continue;
		if (sib.type.isError || BRACKETS.has(sib.name)) return null;
		return whole(sib) ? sib : null;
	}
	return null;
}

/** Whether two carets' changed spans, each in document order, interfere,
 *  as `edit` says. A caret's insertion at the start or end of the other's
 *  change composes as each caret meant unless their changes interleave,
 *  as when one slurps the other's list. */
function clash(spans: [number, number][], other: [number, number][]): boolean {
	const meet = spans.some(([from, to]) =>
		other.some(([a, b]) => (from < b && a < to) || ((from === to || a === b) && from <= b && a <= to)),
	);
	if (!meet) return false;
	const [from, to] = [spans[0][0], spans[spans.length - 1][1]];
	const [a, b] = [other[0][0], other[other.length - 1][1]];
	return from < b && a < to;
}

/** The changes, and the selection mapped through them, for each range's
 *  head: `edit` returns the changes for one caret, or null. A caret is
 *  left as it is when one of its changes overlaps an earlier caret's, or
 *  inserts at or inside text the other replaces or the other way round,
 *  and the text from its first change to its last overlaps the earlier
 *  caret's: a second caret in the same list, or in a list the first
 *  slurps. Lines the changes reach re-indent. `applied` is given each
 *  caret's changes that are kept. Null when no range changes. */
function edit(
	state: EditorState,
	userEvent: string,
	command: (pos: number) => { changes: ChangeSpec[]; cursor?: number; assoc?: -1 | 1 } | null,
	applied?: (set: ChangeSet) => void,
): TransactionSpec | null {
	let changed = false;
	const touched: [number, number][][] = [];
	const spec = state.changeByRange((range: SelectionRange) => {
		const result = command(range.head);
		if (!result) return { range };
		const set = state.changes(result.changes);
		const spans: [number, number][] = [];
		set.iterChangedRanges((from, to) => spans.push([from, to]));
		if (touched.some((other) => clash(spans, other))) return { range };
		touched.push(spans);
		changed = true;
		applied?.(set);
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

/** Pull the form after the caret's collection into it; when no form
 *  follows it, the form after the nearest enclosing collection that has
 *  one. */
export function slurpForward(state: EditorState): TransactionSpec | null {
	return edit(state, "edit.slurp", (pos) => {
		for (let coll = enclosing(state, pos); coll; coll = enclosing(state, element(coll).from)) {
			const closer = closerOf(coll);
			if (!closer) return null;
			if (inPrefix(coll)) return null;
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
		if (!coll || !closer || !coll.firstChild || inPrefix(coll)) return null;
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

/** Pull the form before the caret's collection into it; when no form
 *  precedes it, the form before the nearest enclosing collection that has
 *  one. */
export function slurpBackward(state: EditorState): TransactionSpec | null {
	return edit(state, "edit.slurp", (pos) => {
		for (let coll = enclosing(state, pos); coll; coll = enclosing(state, element(coll).from)) {
			if (!closerOf(coll) || !coll.firstChild) return null;
			if (inPrefix(coll)) return null;
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
		if (!coll || !closer || !coll.firstChild || inPrefix(coll)) return null;
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

/** Remove the brackets of the caret's collection, with any prefix forms
 *  wrapping it, keeping its forms. */
export function splice(state: EditorState): TransactionSpec | null {
	return edit(state, "edit.splice", (pos) => {
		const coll = enclosing(state, pos);
		const closer = coll && closerOf(coll);
		if (!coll || !closer || !coll.firstChild || inPrefix(coll)) return null;
		return {
			changes: [
				{ from: element(coll).from, to: coll.firstChild.to },
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
		if (!coll || !closerOf(coll) || inPrefix(coll)) return null;
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

/** The items ⇧⌘↑/⇧⌘↓ move in Clojure where they are not each child.
 *  None for metadata, a reader tag or a record literal with its form, so
 *  neither part moves off the other. A map's items are each entry from
 *  its key to its value, with any `#_` form between them, and each other
 *  `#_` form on its own; none for a map without a value for each key.
 *  Null for any other node, a set's braces included, which parse as a
 *  map inside the set. */
export const clojureItems: Entries = (node) => {
	if (PREFIX_CONTAINERS.has(node.name)) return [];
	if (node.name !== "Map" || node.parent?.name === "Set") return null;
	const items: Span[] = [];
	let key: SyntaxNode | null = null;
	for (const form of forms(node)) {
		if (form.name === "Discard") {
			if (!key) items.push({ from: form.from, to: form.to });
		} else if (key) {
			items.push({ from: key.from, to: form.to });
			key = null;
		} else key = form;
	}
	return key ? [] : items;
};

/** Wrap the form at the caret in `open` and its closer, as Cursive's
 *  Wrap with () / [] / {} do: the form the caret is in or before, else
 *  the one it is after, else an empty pair. A selection is wrapped as
 *  typing `open` wraps it. */
export function wrap(state: EditorState, open: "(" | "[" | "{"): TransactionSpec | null {
	if (state.selection.ranges.some((r) => !r.empty)) return typeBracket(state, open);
	return edit(state, "edit.wrap", (pos) => {
		if (inText(state, pos)) return null;
		const all = forms(enclosing(state, pos) ?? syntaxTree(state).topNode);
		const form =
			all.find((f) => f.from <= pos && pos < f.to) ?? all.find((f) => f.from >= pos) ?? all.find((f) => f.to === pos);
		if (!form) return { changes: [{ from: pos, insert: open + PAIRS[open] }], cursor: pos + 1 };
		if (!whole(form)) return null;
		return {
			changes: [
				{ from: form.from, insert: open },
				{ from: form.to, insert: PAIRS[open] },
			],
			cursor: form.from + 1,
		};
	});
}

/** The closed string, not a regex's, whose quotes hold `pos`. */
function stringAt(state: EditorState, pos: number): SyntaxNode | null {
	for (let node: SyntaxNode | null = syntaxTree(state).resolveInner(pos, -1); node; node = node.parent) {
		if (node.name !== "String") continue;
		const last = node.lastChild;
		const closed = last !== null && last.name === '"' && last.from > node.from;
		return closed && node.parent?.name !== "RegExp" && node.from < pos && pos < node.to ? node : null;
	}
	return null;
}

/** Whether the character before `pos` is escaped away by a backslash. */
function afterEscape(state: EditorState, pos: number): boolean {
	const before = state.doc.sliceString(Math.max(0, pos - 64), pos);
	return /(^|[^\\])(\\\\)*\\$/.test(before);
}

/** Split the string or collection at the caret in two, as Cursive's
 *  Split does: `(a |b)` becomes `(a)| (b)`. Not inside a form. */
export function split(state: EditorState): TransactionSpec | null {
	return edit(state, "edit.split", (pos) => {
		const str = stringAt(state, pos);
		if (str) return afterEscape(state, pos) ? null : { changes: [{ from: pos, insert: '" "' }], cursor: pos + 1 };
		if (inText(state, pos)) return null;
		const coll = enclosing(state, pos);
		const closer = coll && closerOf(coll);
		if (!coll || !closer || !coll.firstChild || inPrefix(coll)) return null;
		if (forms(coll).some((f) => f.from < pos && pos < f.to)) return null;
		let from = pos;
		while (from > coll.firstChild.to && /[ \t]/.test(state.doc.sliceString(from - 1, from))) from--;
		let to = pos;
		while (to < closer.from && /[ \t]/.test(state.doc.sliceString(to, to + 1))) to++;
		// Each half keeps the prefixes on the collection, such as `#_` or `'`.
		const opener = state.doc.sliceString(element(coll).from, coll.firstChild.to);
		return { changes: [{ from, to, insert: `${closer.name} ${opener}` }], cursor: from + 1 };
	});
}

/** The collection `form` is, or ends with under its prefixes, such as
 *  `#`, `'`, `@` or `#_`. */
function collOf(form: SyntaxNode): SyntaxNode | null {
	let node: SyntaxNode | null = form;
	while (node && !isColl(node)) node = node.lastChild?.to === node.to ? node.lastChild : null;
	return node;
}

/** Join the two forms either side of the caret into one, as Cursive's
 *  Join does: `(a)| (b)` becomes `(a| b)`, `"a"| "b"` becomes `"a|b"`.
 *  Both must be strings, or collections of the same kind. */
export function joinForms(state: EditorState): TransactionSpec | null {
	return edit(state, "edit.join", (pos) => {
		const all = forms(enclosing(state, pos) ?? syntaxTree(state).topNode);
		const prev = all.findLast((f) => f.to <= pos);
		const next = all.find((f) => f.from >= pos);
		if (!prev || !next || !whole(prev) || sibling(prev, 1)?.from !== next.from || prev.name !== next.name) return null;
		if (prev.name === "String" && stringAt(state, prev.to - 1) && stringAt(state, next.from + 1)) {
			return { changes: [{ from: prev.to - 1, to: next.from + 1 }], cursor: prev.to - 1 };
		}
		const left = collOf(prev);
		const right = collOf(next);
		const closer = left && closerOf(left);
		const opener = right?.firstChild;
		if (!left?.firstChild || !right || !closer || !opener) return null;
		const leftOpener = state.doc.sliceString(prev.from, left.firstChild.to);
		if (leftOpener !== state.doc.sliceString(next.from, opener.to)) return null;
		const gap = state.doc.sliceString(closer.to, next.from);
		const changes: ChangeSpec[] =
			(forms(left).length === 0 || forms(right).length === 0) && gap.trim() === ""
				? [{ from: closer.from, to: opener.to }]
				: [
						{ from: closer.from, to: closer.to, insert: gap === "" ? " " : "" },
						{ from: next.from, to: opener.to },
					];
		return { changes, cursor: closer.from };
	});
}

/** Where Kill from `pos` stops: the end of the line, or before the
 *  enclosing collection's closer or string's quote when that comes
 *  first, pushed past any form that crosses the line's end. At the end of
 *  a line, past the line break. Null when that would unbalance brackets. */
function killEnd(state: EditorState, pos: number): number | null {
	const line = state.doc.lineAt(pos);
	const str = stringAt(state, pos);
	if (str) return afterEscape(state, pos) ? null : Math.min(line.to, str.to - 1);
	if (inText(state, pos)) {
		const comment = syntaxTree(state).resolveInner(pos, -1);
		return comment.name === "LineComment" ? line.to : null;
	}
	const coll = enclosing(state, pos);
	const parent = coll ?? syntaxTree(state).topNode;
	let limit = coll ? (closerOf(coll)?.from ?? state.doc.length) : state.doc.length;
	for (let child = parent.firstChild; child; child = child.nextSibling) {
		const stray = child.type.isError || (BRACKETS.has(child.name) && child !== parent.firstChild);
		if (stray && child.from >= pos && child.from < limit) limit = child.from;
	}
	let end = Math.min(line.to, limit);
	if (end === pos) return pos === line.to && pos < limit ? pos + 1 : null;
	for (const f of forms(parent)) {
		if (f.to <= pos || f.from >= end) continue;
		const token = f.firstChild === null || f.name === "Operator";
		if (f.from < pos && !token) return null;
		if (f.to > end) {
			if (!whole(f)) return null;
			end = f.to;
		}
	}
	return end;
}

/** Cut from the caret to the end of its line or of its enclosing
 *  collection or string, as Cursive's Kill does, keeping brackets
 *  balanced: the transaction, and the text it cuts. */
export function kill(state: EditorState): { spec: TransactionSpec; text: string } | null {
	const cut: string[] = [];
	const spec = edit(
		state,
		"delete.cut",
		(pos) => {
			const end = killEnd(state, pos);
			return end === null || end === pos ? null : { changes: [{ from: pos, to: end }] };
		},
		(set) => set.iterChanges((from, to) => cut.push(state.doc.sliceString(from, to))),
	);
	return spec && { spec, text: cut.join("\n") };
}

type Thread = "->" | "->>";

/** The source text of `node`. */
function text(state: EditorState, node: SyntaxNode): string {
	return state.doc.sliceString(node.from, node.to);
}

/** The forms in `parent` that are code: its forms but the `#_` ones. */
function live(parent: SyntaxNode): SyntaxNode[] {
	return forms(parent).filter((f) => f.name !== "Discard");
}

/** Whether `coll` is a plain list, with no prefix in its opener such as
 *  `#?(`, so a call. */
function isCall(coll: SyntaxNode): boolean {
	return coll.name === "List" && openStart(coll) === coll.from;
}

/** The threading macro `coll` is a call to, if any. */
function threadOf(state: EditorState, coll: SyntaxNode): Thread | null {
	const head = isCall(coll) ? live(coll)[0] : undefined;
	const name = head && text(state, head);
	return name === "->" || name === "->>" ? name : null;
}

/** `call` without its argument `arg`, as a threading step: `(f b)` for
 *  `(f a b)` without `a`, or just `f` when nothing else is left. */
function stepWithout(state: EditorState, call: SyntaxNode, arg: SyntaxNode): string {
	const all = forms(call);
	if (all.length === 2 && (all[0].name === "Operator" || all[0].name === "Keyword")) return text(state, all[0]);
	const i = all.findIndex((f) => f.from === arg.from);
	const [from, to] = i === all.length - 1 ? [all[i - 1].to, arg.to] : [arg.from, all[i + 1].from];
	return state.doc.sliceString(call.from, from) + state.doc.sliceString(to, call.to);
}

/** Thread the caret's list one step with `macro` (`->` threads its first
 *  argument, `->>` its last): `(f (g x) b)` becomes `(-> (g x) (f b))`.
 *  In a list that already threads with `macro`, its threaded value is
 *  threaded one step further: `(-> (g x) f)` becomes `(-> x g f)`. The
 *  caret lands before the threaded value. */
export function thread(state: EditorState, macro: Thread): TransactionSpec | null {
	return edit(state, "edit.thread", (pos) => {
		const coll = enclosing(state, pos);
		if (!coll || !isCall(coll) || !closerOf(coll) || !whole(coll)) return null;
		const all = live(coll);
		const pick = (args: SyntaxNode[]) => (macro === "->" ? args[1] : args[args.length - 1]);
		const existing = threadOf(state, coll);
		if (existing) {
			const value = all[1];
			if (existing !== macro || !value || !isCall(value) || live(value).length < 2) return null;
			const arg = pick(live(value));
			return {
				changes: [{ from: value.from, to: value.to, insert: `${text(state, arg)} ${stepWithout(state, value, arg)}` }],
				cursor: value.from,
			};
		}
		if (all.length < 2) return null;
		const arg = pick(all);
		return {
			changes: [
				{ from: coll.from, to: coll.to, insert: `(${macro} ${text(state, arg)} ${stepWithout(state, coll, arg)})` },
			],
			cursor: coll.from + macro.length + 2,
		};
	});
}

/** Undo one step of the nearest `->` or `->>` around the caret, as
 *  Cursive's Unthread Form does: `(-> x g f)` becomes `(-> (g x) f)`, and
 *  `(-> (g x))` or `(-> x g)` becomes `(g x)`. */
export function unthread(state: EditorState): TransactionSpec | null {
	return edit(state, "edit.unthread", (pos) => {
		for (let coll = enclosing(state, pos); coll; coll = enclosing(state, element(coll).from)) {
			if (!closerOf(coll)) return null;
			const macro = threadOf(state, coll);
			if (!macro) continue;
			if (!whole(coll)) return null;
			const [, value, step] = live(coll);
			// The thread becomes the call only when it holds no other form,
			// such as a `#_` one, that would go with it.
			const alone = forms(coll).length === (step ? 3 : 2);
			if (!value || (!step && !alone)) return null;
			if (!step) return { changes: [{ from: coll.from, to: coll.to, insert: text(state, value) }], cursor: coll.from };
			let call: string;
			if (step.name === "List") {
				const args = forms(step);
				const closer = closerOf(step) as SyntaxNode;
				const at = macro === "->" ? (args[1]?.from ?? closer.from) : closer.from;
				const lead = macro === "->" && args[1] ? "" : " ";
				const trail = macro === "->" && args[1] ? " " : "";
				call =
					state.doc.sliceString(step.from, at) + lead + text(state, value) + trail + state.doc.sliceString(at, step.to);
			} else if (step.name === "Symbol" || step.name === "Keyword") {
				call = `(${text(state, step)} ${text(state, value)})`;
			} else return null;
			if (alone) return { changes: [{ from: coll.from, to: coll.to, insert: call }], cursor: coll.from };
			// The step goes from after the form before it, keeping any `#_`
			// form between the value and the step.
			const before = forms(coll).findLast((f) => f.to <= step.from) as SyntaxNode;
			return {
				changes: [
					{ from: value.from, to: value.to, insert: call },
					{ from: before.to, to: step.to },
				],
				cursor: value.from,
			};
		}
		return null;
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

/** The matched collection a form with a prefix in its opener (`#{`, `#?@(`,
 *  `#:a{`) opens, or null when it opens no matched collection. */
function prefixedColl(node: SyntaxNode): SyntaxNode | null {
	const last = node.lastChild;
	const coll = last?.name === "Deref" ? last.lastChild : last;
	return coll && isColl(coll) && closerOf(coll) ? coll : null;
}

/** The matched collection whose prefix holds the character at `at`, as
 *  `#` does in `#{`: the `#`, `#?` or `#?@` before its opener, or the
 *  `#:` or `#::` of a namespaced map, whose namespace stays plain text. */
function prefixOf(state: EditorState, at: number): SyntaxNode | null {
	if (at < 0 || at >= state.doc.length) return null;
	for (let node: SyntaxNode | null = syntaxTree(state).resolveInner(at, 1); node; node = node.parent) {
		if (!PREFIXED.has(node.name)) continue;
		const coll = prefixedColl(node);
		if (!coll) return null;
		if (node.name !== "NamespacedMap") return at < coll.from ? coll : null;
		const autoResolved = state.doc.sliceString(node.from, node.from + 3) === "#::";
		return at < node.from + (autoResolved ? 3 : 2) ? coll : null;
	}
	return null;
}

/** Backspace (`dir` -1) or Delete (`dir` 1) at a caret beside a bracket
 *  of a matched pair, or its opener's prefix: steps over it, or deletes the
 *  pair when the caret sits inside it and it is empty. Null when no caret
 *  is beside one, so the editor's own deletion runs; a selection always
 *  deletes. While any caret is guarded, the other carets delete one
 *  character here, not through the editor's own deletion. */
export function deleteGuarded(state: EditorState, dir: -1 | 1): TransactionSpec | null {
	if (state.selection.ranges.some((r) => !r.empty)) return null;
	let guarded = false;
	const spec = state.changeByRange((range) => {
		const pos = range.head;
		const at = dir < 0 ? pos - 1 : pos;
		const coll = prefixOf(state, at);
		if (coll?.firstChild) {
			guarded = true;
			return { range: EditorSelection.cursor(dir < 0 ? openStart(coll) : coll.firstChild.to) };
		}
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
			const from = openStart(parent);
			const set = state.changes({ from, to: closer.to });
			return { changes: set, range: EditorSelection.cursor(from) };
		}
		// Backspace steps over a prefix with its opener.
		const to = dir < 0 && bracket.node.from === opener.from ? openStart(parent) : pos + dir;
		return { range: EditorSelection.cursor(to) };
	});
	if (!guarded) return null;
	return { ...spec, scrollIntoView: true, userEvent: dir < 0 ? "delete.backward" : "delete.forward" };
}

/** Whether `pos` sits in a string (a regex's included, after its `#`),
 *  a comment or a character literal, or just after a `\`, where
 *  brackets are text. A string with no closing quote runs to the end of
 *  the text. */
function inText(state: EditorState, pos: number): boolean {
	return textStart(state, pos) !== null;
}

/** Where the text that `inText` says `pos` sits in starts: its string,
 *  comment or character literal, or its `\`. Null in code. */
function textStart(state: EditorState, pos: number): number | null {
	for (let node: SyntaxNode | null = syntaxTree(state).resolveInner(pos, -1); node; node = node.parent) {
		if (node.name === "String") return inString(node, pos) ? node.from : null;
		if (node.name === "LineComment") return node.from < pos ? node.from : null;
		if (node.name === "Character") return node.from < pos && pos < node.to ? node.from : null;
	}
	return state.doc.sliceString(pos - 1, pos) === "\\" ? pos - 1 : null;
}

/** Whether a selection end at `pos` splits a prefix from what it applies
 *  to: a matched collection's opener from the prefix that is part of it,
 *  as one between `#` and `{`, or in or after the namespace of `#:ns{`,
 *  does; any position inside a symbolic value such as `##Inf` does; or
 *  any other node that is no collection, such as a prefix form (`'`,
 *  `^:m`, `#_`, `#'`, `#inst`), from the child it ends with. The
 *  selection's start (`end` false) may sit at that child, but its end
 *  may not, as wrapping would leave the prefix without one. No selection
 *  may start at the child of a form in `NARROW_PREFIXED` either: a
 *  record literal's map or vector, a regex's string or a var's symbol,
 *  as its prefix takes no other. A `pos` inside a collection, as in a
 *  metadata map, splits no prefix outside that collection. */
function splitsPrefix(state: EditorState, pos: number, end: boolean): boolean {
	for (let node: SyntaxNode | null = syntaxTree(state).resolveInner(pos, -1); node; node = node.parent) {
		if (node.from >= pos) continue;
		// Inside a collection, no prefix outside it can be split.
		if (isColl(node)) {
			if (holds(node, pos)) return false;
			continue;
		}
		if (node.name === "SymbolicValue" && pos < node.to) return true;
		const coll = PREFIXED.has(node.name) ? prefixedColl(node) : null;
		if (coll?.firstChild && pos < coll.firstChild.to) return true;
		const form = node.lastChild;
		if (!node.parent || !form || form.to !== node.to) continue;
		if ((end || NARROW_PREFIXED.has(node.name)) ? pos <= form.from : pos < form.from) return true;
	}
	return false;
}

/** Whether `range` cuts across brackets: it holds a bracket whose partner
 *  is outside it or missing, one of its ends `splitsPrefix`, or one of
 *  its ends is where `inText` says brackets are text, as `typeBracket`
 *  asks only of a range not within one text. */
function cutsAcross(state: EditorState, range: SelectionRange): boolean {
	if (range.empty) return false;
	const { from, to } = range;
	if (inText(state, from) || inText(state, to)) return true;
	if (splitsPrefix(state, from, false) || splitsPrefix(state, to, true)) return true;
	let cut = false;
	syntaxTree(state).iterate({
		from,
		to,
		enter: (node) => {
			if (cut || !BRACKETS.has(node.name) || node.from < from || node.to > to) return !cut;
			const coll = node.node.parent;
			const closer = coll && isColl(coll) ? closerOf(coll) : null;
			cut = !coll || !closer || openStart(coll) < from || closer.to > to;
			return !cut;
		},
	});
	return cut;
}

/** Typing `text`: an opener inserts its closer too, around a selection if
 *  there is one, and leaves a selection that `cutsAcross` brackets as it
 *  is; a closer before the same matched closer steps over it. At a caret
 *  where `inText` says brackets are text, or over a selection within one
 *  such text, an opener is typed as text. Null, so the editor types
 *  `text` itself, for anything else, for an opener where every range is
 *  so typed as text, and for a closer where any range is in text, as no
 *  bracket in text is matched. */
export function typeBracket(state: EditorState, text: string): TransactionSpec | null {
	if (!(text in PAIRS || Object.values(PAIRS).includes(text))) return null;
	const ranges = state.selection.ranges;
	const textAt = (r: SelectionRange) => {
		const start = textStart(state, r.from);
		return start !== null && textStart(state, r.to) === start;
	};
	if (text in PAIRS) {
		if (ranges.every(textAt)) return null;
		return {
			...state.changeByRange((range) => {
				if (textAt(range)) {
					return {
						changes: { from: range.from, to: range.to, insert: text },
						range: EditorSelection.cursor(range.from + 1),
					};
				}
				if (cutsAcross(state, range)) return { range };
				return {
					changes: [
						{ from: range.from, insert: text },
						{ from: range.to, insert: PAIRS[text] },
					],
					range: range.empty
						? EditorSelection.cursor(range.from + 1)
						: EditorSelection.range(range.from + 1, range.to + 1),
				};
			}),
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

/** Whether no space belongs between the text ending at `end` and the
 *  text starting at `start` when lines join: none after an opening
 *  bracket or before a closing one, though a `\(` character takes one. */
export function tightInClojure(state: EditorState, end: number, start: number): boolean {
	const tree = syntaxTree(state);
	const before = tree.resolveInner(end, -1);
	const after = tree.resolveInner(start, 1);
	return (before.to === end && before.name in PAIRS) || (after.from === start && Object.values(PAIRS).includes(after.name));
}

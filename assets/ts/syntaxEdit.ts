import { syntaxTree } from "@codemirror/language";
import {
	EditorSelection,
	type EditorState,
	type SelectionRange,
	StateEffect,
	StateField,
	type Transaction,
	type TransactionSpec,
} from "@codemirror/state";

/** Editing commands over any language's syntax tree, and joining lines,
 *  which needs none. Each takes a state and returns the transaction to
 *  dispatch, or null when it does nothing there. */

type SyntaxNode = ReturnType<typeof syntaxTree>["topNode"];

const OPENERS: Record<string, string> = { "(": ")", "[": "]", "{": "}", '"': '"' };

/** The range inside `node`'s brackets, without the whitespace at either
 *  end, or null when `node` is not bracketed. */
function interior(state: EditorState, node: SyntaxNode): { from: number; to: number } | null {
	const first = node.firstChild;
	const last = node.lastChild;
	if (!first || !last || first === last || OPENERS[first.name] !== last.name) return null;
	if (first.to - first.from !== 1 || last.to - last.from !== 1) return null;
	const text = state.doc.sliceString(first.to, last.from);
	const from = first.to + (text.length - text.trimStart().length);
	const to = Math.max(from, last.from - (text.length - text.trimEnd().length));
	return { from, to };
}

/** The next range out from `range`: the word at a caret, then each
 *  enclosing node, the inside of its brackets before the node itself. */
function expandRange(state: EditorState, range: SelectionRange): { from: number; to: number } | null {
	const { from, to } = range;
	if (range.empty) {
		const word = state.wordAt(from);
		if (word && word.from < word.to) return word;
	}
	const larger = (r: { from: number; to: number } | null) =>
		r !== null && r.from <= from && r.to >= to && r.to - r.from > to - from;
	for (let node: SyntaxNode | null = syntaxTree(state).resolveInner(from, 1); node; node = node.parent) {
		if (node.from > from || node.to < to) continue;
		const inside = interior(state, node);
		if (larger(inside)) return inside;
		if (larger(node)) return { from: node.from, to: node.to };
	}
	return null;
}

const pushSelection = StateEffect.define<EditorSelection>();
const popSelection = StateEffect.define<null>();

/** The selections that ⌥↑ expanded from, latest last, so ⌥↓ steps back
 *  through them. Any other selection change or edit forgets them. */
export const selectionHistory = StateField.define<EditorSelection[]>({
	create: () => [],
	update(stack, tr: Transaction) {
		for (const effect of tr.effects) {
			if (effect.is(pushSelection)) return [...stack, effect.value];
			if (effect.is(popSelection)) return stack.slice(0, -1);
		}
		return tr.docChanged || tr.selection ? [] : stack;
	},
});

/** Expand each selection range to the next enclosing syntax unit. */
export function expandSelection(state: EditorState): TransactionSpec | null {
	if (syntaxTree(state).length === 0) return null;
	let grew = false;
	const ranges = state.selection.ranges.map((range) => {
		const next = expandRange(state, range);
		if (!next) return range;
		grew = true;
		return EditorSelection.range(next.from, next.to);
	});
	if (!grew) return null;
	return {
		selection: EditorSelection.create(ranges, state.selection.mainIndex),
		effects: pushSelection.of(state.selection),
		userEvent: "select",
	};
}

/** Step back to the selection the last expansion started from. */
export function shrinkSelection(state: EditorState): TransactionSpec | null {
	const stack = state.field(selectionHistory, false);
	if (!stack?.length) return null;
	return { selection: stack[stack.length - 1], effects: popSelection.of(null), userEvent: "select" };
}

const SEPARATORS = new Set([",", ";"]);

/** Whether `node` is a unit worth moving: a named node that is not a
 *  comment, an error, a keyword or bracket token, or an operator. */
function movable(state: EditorState, node: SyntaxNode): boolean {
	if (node.type.isError || !/^[A-Z]/.test(node.name) || /Comment/.test(node.name)) return false;
	return node.firstChild !== null || !/^[^\w\s"'`]+$/.test(state.doc.sliceString(node.from, node.to));
}

/** The node `node` would swap with moving by `dir`: the next movable
 *  sibling across only whitespace, comments and separators. Null when a
 *  bracket, keyword or operator comes first, or nothing parts them. */
function swapPartner(state: EditorState, node: SyntaxNode, dir: -1 | 1): SyntaxNode | null {
	for (let sib = dir > 0 ? node.nextSibling : node.prevSibling; sib; sib = dir > 0 ? sib.nextSibling : sib.prevSibling) {
		if (SEPARATORS.has(sib.name) || /Comment/.test(sib.name)) continue;
		if (!movable(state, sib)) return null;
		const gap = dir > 0 ? sib.from - node.to : node.from - sib.to;
		return gap > 0 ? sib : null;
	}
	return null;
}

/** The innermost node holding the main selection: for a caret, the one
 *  after it, or before it at the end of a line or before a space. */
function nodeAtSelection(state: EditorState): SyntaxNode {
	const { from, to, empty } = state.selection.main;
	const tree = syntaxTree(state);
	if (!empty) {
		let node: SyntaxNode | null = tree.resolveInner(from, 1);
		while (node.parent && (node.from > from || node.to < to)) node = node.parent;
		return node;
	}
	const next = state.doc.sliceString(from, from + 1);
	return tree.resolveInner(from, next === "" || /\s/.test(next) ? -1 : 1);
}

/** Swap the node at the main selection with its previous (`dir` -1) or
 *  next sibling: the smallest enclosing node that has one, such as a
 *  statement, a list element, an argument or an object property. The
 *  selection moves with the node. */
export function moveNode(state: EditorState, dir: -1 | 1): TransactionSpec | null {
	if (syntaxTree(state).length === 0) return null;
	for (let node: SyntaxNode | null = nodeAtSelection(state); node?.parent; node = node.parent) {
		if (!movable(state, node)) continue;
		const partner = swapPartner(state, node, dir);
		if (!partner) continue;
		const [a, b] = dir > 0 ? [node, partner] : [partner, node];
		const textA = state.doc.sliceString(a.from, a.to);
		const textB = state.doc.sliceString(b.from, b.to);
		// Where the node starts once moved.
		const start = dir > 0 ? b.to - textA.length : a.from;
		const { anchor, head } = state.selection.main;
		const shift = start - node.from;
		return {
			changes: [
				{ from: a.from, to: a.to, insert: textB },
				{ from: b.from, to: b.to, insert: textA },
			],
			selection: EditorSelection.single(anchor + shift, head + shift),
			scrollIntoView: true,
			userEvent: "move.node",
		};
	}
	return null;
}

/** Whether no space belongs between `before` and `after` when a join
 *  puts them side by side. */
export type Tight = (before: string, after: string) => boolean;

/** Join the line after each caret's line onto it, or all the lines a
 *  selection touches. Each line break and the whitespace around it become
 *  one space, or nothing when either line is blank or `tight` says so. */
export function joinLines(state: EditorState, tight: Tight = () => false): TransactionSpec | null {
	const doc = state.doc;
	let joined = false;
	const spec = state.changeByRange((range) => {
		const first = doc.lineAt(range.from).number;
		const last = Math.max(first + 1, doc.lineAt(range.to).number);
		if (last > doc.lines) return { range };
		joined = true;
		const changes = [];
		let caret = range.from;
		for (let n = first; n < last; n++) {
			const line = doc.line(n);
			const next = doc.line(n + 1);
			const end = line.from + line.text.trimEnd().length;
			const start = next.to - next.text.trimStart().length;
			if (end === line.from) {
				// A blank line goes, and the next keeps its indentation.
				changes.push({ from: line.from, to: next.from });
				caret = line.from;
			} else {
				const before = doc.sliceString(end - 1, end);
				const after = doc.sliceString(start, start + 1);
				const insert = start === next.to || tight(before, after) ? "" : " ";
				changes.push({ from: end, to: start, insert });
				caret = end;
			}
		}
		const set = state.changes(changes);
		return {
			changes: set,
			range: range.empty
				? EditorSelection.cursor(set.mapPos(caret, -1))
				: EditorSelection.range(set.mapPos(range.anchor, -1), set.mapPos(range.head, 1)),
		};
	});
	return joined ? { ...spec, scrollIntoView: true, userEvent: "input.join" } : null;
}

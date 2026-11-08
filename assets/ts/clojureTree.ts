import type { SyntaxNode } from "./syntaxEdit.js";

/** Reading the Lezer tree of `@nextjournal/lang-clojure`, shared by the
 *  indenter and the structural editing commands. */

export type { SyntaxNode };

export const CLOSERS: Readonly<Record<string, string>> = { List: ")", Vector: "]", Map: "}" };
export const BRACKETS: ReadonlySet<string> = new Set(["(", ")", "[", "]", "{", "}"]);

export function isColl(node: SyntaxNode): boolean {
	return node.name in CLOSERS;
}

/** The closing bracket of `coll`, or null when the text lacks it. */
export function closerOf(coll: SyntaxNode): SyntaxNode | null {
	const last = coll.lastChild;
	return last && last.name === CLOSERS[coll.name] ? last : null;
}

/** Whether `pos`, after `coll`'s opener starts, is before its closer. A
 *  collection with no closer, such as one the editor's lines cut off
 *  from it, holds everything after its opener. */
export function holds(coll: SyntaxNode, pos: number): boolean {
	const closer = closerOf(coll);
	return !closer || pos <= closer.from;
}

/** Whether `node`, a String, has its closing quote: the quote it opens
 *  with is its first child. */
export function closedString(node: SyntaxNode): boolean {
	const last = node.lastChild;
	return last !== null && last.name === '"' && last.from > node.from;
}

/** `coll`'s parent, or when `coll` is dereffed, the deref's parent: for
 *  `#?@(`, which parses as a deref, the reader conditional around the
 *  `@`. */
export function holder(coll: SyntaxNode): SyntaxNode | null {
	return coll.parent?.name === "Deref" ? coll.parent.parent : coll.parent;
}

/** The forms in a collection or the program, `#_` forms included, as
 *  rewrite-clj's zipper steps through them: comments, brackets and stray
 *  tokens are left out. */
export function forms(parent: SyntaxNode): SyntaxNode[] {
	const out: SyntaxNode[] = [];
	for (let child = parent.firstChild; child; child = child.nextSibling) {
		if (!BRACKETS.has(child.name) && child.name !== "LineComment" && !child.type.isError) out.push(child);
	}
	return out;
}

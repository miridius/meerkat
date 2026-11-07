import type { SyntaxNode } from "./syntaxEdit.js";

/** Reading the Lezer tree of `@nextjournal/lang-clojure`, shared by the
 *  indenter and the structural editing commands. */

export type { SyntaxNode };

export const CLOSERS: Readonly<Record<string, string>> = { List: ")", Vector: "]", Map: "}" };
export const BRACKETS: ReadonlySet<string> = new Set(["(", ")", "[", "]", "{", "}"]);

export function isColl(node: SyntaxNode): boolean {
	return node.name in CLOSERS;
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

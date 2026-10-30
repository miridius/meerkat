import type { syntaxTree } from "@codemirror/language";

/** Reading the Lezer tree of `@nextjournal/lang-clojure`, shared by the
 *  indenter and the structural editing commands. */

export type SyntaxNode = ReturnType<typeof syntaxTree>["topNode"];

export const CLOSERS: Record<string, string> = { List: ")", Vector: "]", Map: "}" };
export const BRACKETS = new Set(["(", ")", "[", "]", "{", "}"]);

export function isColl(node: SyntaxNode): boolean {
	return node.name in CLOSERS;
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

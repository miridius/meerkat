import { type IndentContext, indentService, syntaxTree } from "@codemirror/language";

/** Clojure indentation by cljfmt's default rules (`:community` function
 *  arguments, its default indent table), computed over the Lezer tree of
 *  `@nextjournal/lang-clojure`. That pack's own rule indents every list's
 *  arguments two spaces; cljfmt aligns a call's arguments with its first
 *  argument and keeps two spaces for the bodies of forms like `defn` and
 *  `let`.
 *
 *  The rule names below are cljfmt's (`cljfmt/core.cljc`): `zloc` is the
 *  element that starts the line being indented, and its index counts the
 *  list's head as 0. */

type SyntaxNode = ReturnType<typeof syntaxTree>["topNode"];

type Spec = { kind: "inner"; depth: number; index?: number } | { kind: "block"; index: number };

const inner = (depth: number, index?: number): Spec => ({ kind: "inner", depth, index });
const block = (index: number): Spec => ({ kind: "block", index });

/** cljfmt's default indents: `cljfmt/indents/clojure.clj`,
 *  `compojure.clj` and `fuzzy.clj`. */
const DEFAULT_INDENTS: [string | RegExp, Spec[]][] = [
	["alt!", [block(0)]],
	["alt!!", [block(0)]],
	["are", [block(2)]],
	["as->", [block(2)]],
	["binding", [block(1)]],
	["bound-fn", [inner(0)]],
	["case", [block(1)]],
	["catch", [block(2)]],
	["comment", [block(0)]],
	["cond", [block(0)]],
	["condp", [block(2)]],
	["cond->", [block(1)]],
	["cond->>", [block(1)]],
	["def", [inner(0)]],
	["defmacro", [inner(0)]],
	["defmethod", [inner(0)]],
	["defmulti", [inner(0)]],
	["defn", [inner(0)]],
	["defn-", [inner(0)]],
	["defonce", [inner(0)]],
	["defprotocol", [block(1), inner(1)]],
	["defrecord", [block(2), inner(1)]],
	["defstruct", [block(1)]],
	["deftest", [inner(0)]],
	["deftype", [block(2), inner(1)]],
	["delay", [block(0)]],
	["do", [block(0)]],
	["doseq", [block(1)]],
	["dotimes", [block(1)]],
	["doto", [block(1)]],
	["extend", [block(1)]],
	["extend-protocol", [block(1), inner(1)]],
	["extend-type", [block(1), inner(1)]],
	["fdef", [inner(0)]],
	["finally", [block(0)]],
	["fn", [inner(0)]],
	["for", [block(1)]],
	["future", [block(0)]],
	["go", [block(0)]],
	["go-loop", [block(1)]],
	["if", [block(1)]],
	["if-let", [block(1)]],
	["if-not", [block(1)]],
	["if-some", [block(1)]],
	["let", [block(1)]],
	["let*", [block(1)]],
	["letfn", [block(1), inner(2, 0)]],
	["locking", [block(1)]],
	["loop", [block(1)]],
	["match", [block(1)]],
	["ns", [block(1)]],
	["proxy", [block(2), inner(1)]],
	["reify", [inner(0), inner(1)]],
	["struct-map", [block(1)]],
	["testing", [block(1)]],
	["thread", [block(0)]],
	["try", [block(0)]],
	["use-fixtures", [inner(0)]],
	["when", [block(1)]],
	["when-first", [block(1)]],
	["when-let", [block(1)]],
	["when-not", [block(1)]],
	["when-some", [block(1)]],
	["while", [block(1)]],
	["with-local-vars", [block(1)]],
	["with-open", [block(1)]],
	["with-out-str", [block(0)]],
	["with-precision", [block(1)]],
	["with-redefs", [block(1)]],
	// compojure.clj
	["ANY", [inner(0)]],
	["DELETE", [inner(0)]],
	["GET", [inner(0)]],
	["HEAD", [inner(0)]],
	["OPTIONS", [inner(0)]],
	["PATCH", [inner(0)]],
	["POST", [inner(0)]],
	["PUT", [inner(0)]],
	["context", [inner(0)]],
	["defroutes", [inner(0)]],
	["let-routes", [block(1)]],
	["rfn", [inner(0)]],
	// fuzzy.clj
	[/^def(?!ault)(?!late)(?!er)/, [inner(0)]],
	[/^with-/, [inner(0)]],
];

/** cljfmt's `indent-order`: deeper inner rules first, then symbols
 *  before patterns, then by name. The first rule that applies wins. */
function indentOrder([key, specs]: [string | RegExp, Spec[]]): [number, number, string] {
	const depth = Math.max(0, ...specs.map((s) => (s.kind === "inner" ? s.depth : 0)));
	return [-depth, typeof key === "string" ? 1 : 2, typeof key === "string" ? key : key.source];
}

const SORTED_INDENTS = DEFAULT_INDENTS.map((entry) => ({ entry, order: indentOrder(entry) }))
	.sort((a, b) => {
		for (let i = 0; i < 3; i++) {
			if (a.order[i] < b.order[i]) return -1;
			if (a.order[i] > b.order[i]) return 1;
		}
		return 0;
	})
	.map(({ entry }) => entry);

const CLOSERS: Record<string, string> = { List: ")", Vector: "]", Map: "}" };
const STRINGS = new Set(["String", "RegExp"]);
const BRACKETS = new Set(["(", ")", "[", "]", "{", "}"]);
const SYMBOLS = new Set(["Symbol", "Operator", "DefLike", "NS"]);

function isColl(node: SyntaxNode): boolean {
	return node.name in CLOSERS;
}

/** The forms in `coll`, `#_` forms included, as rewrite-clj's zipper
 *  steps through them: comments are skipped. */
function forms(coll: SyntaxNode): SyntaxNode[] {
	const out: SyntaxNode[] = [];
	for (let child = coll.firstChild; child; child = child.nextSibling) {
		if (!BRACKETS.has(child.name) && child.name !== "LineComment" && !child.type.isError) {
			out.push(child);
		}
	}
	return out;
}

/** The forms cljfmt's `index-of` counts: `#_` forms are left out. */
function elements(coll: SyntaxNode): SyntaxNode[] {
	return forms(coll).filter((node) => node.name !== "Discard");
}

/** The collection that `pos` sits inside, "string" inside a string, or
 *  null at the top level. An unclosed collection, such as one the editor's
 *  lines cut off from its closer, still holds every position after its
 *  opener. */
function enclosing(tree: ReturnType<typeof syntaxTree>, pos: number): SyntaxNode | "string" | null {
	for (let node: SyntaxNode | null = tree.resolveInner(pos, -1); node; node = node.parent) {
		if (STRINGS.has(node.name) && node.from < pos && pos < node.to) return "string";
		if (isColl(node) && node.from < pos && (pos < node.to || node.lastChild?.name !== CLOSERS[node.name])) {
			return node;
		}
	}
	return null;
}

/** The element `node` belongs to in its parent collection, which wraps it
 *  in `#(...)`, `#{...}`, `#?(...)`, metadata or a quote, and that parent. */
function up(node: SyntaxNode): { element: SyntaxNode; coll: SyntaxNode } | null {
	let element = node;
	for (let parent = node.parent; parent; parent = parent.parent) {
		if (isColl(parent)) return { element, coll: parent };
		element = parent;
	}
	return null;
}

/** cljfmt's `form-symbol`: the name of the symbol heading `coll`, skipping
 *  metadata, without its namespace. */
function headName(cx: IndentContext, coll: SyntaxNode): string | null {
	let head: SyntaxNode | null = forms(coll)[0] ?? null;
	while (head?.name === "Meta") head = head.lastChild;
	if (!head || !SYMBOLS.has(head.name)) return null;
	const text = cx.state.doc.sliceString(head.from, head.to);
	const slash = text.indexOf("/");
	return slash > 0 && slash < text.length - 1 ? text.slice(slash + 1) : text;
}

function matches(key: string | RegExp, name: string | null): boolean {
	if (name === null) return false;
	return typeof key === "string" ? key === name : key.test(name);
}

/** Whether `list` is the body of `#?(...)` or, parsed as a deref inside
 *  one, `#?@(...)`. */
function inReaderConditional(list: SyntaxNode): boolean {
	const parent = list.parent?.name === "Deref" ? list.parent.parent : list.parent;
	return parent?.name === "ReaderConditional";
}

/** Whether `node` starts its line. */
function firstInLine(cx: IndentContext, node: SyntaxNode): boolean {
	const line = cx.lineAt(node.from);
	return line.text.slice(0, node.from - line.from).trim() === "";
}

/** The indentation, in columns, of a line starting at `pos` in a Clojure
 *  document, or null inside a string, where cljfmt leaves lines alone. */
export function clojureIndentation(cx: IndentContext, pos: number): number | null {
	const coll = enclosing(syntaxTree(cx.state), pos);
	if (coll === "string") return null;
	if (coll === null) return 0;

	// cljfmt's `coll-indent`: one column past the opener.
	const collIndent = cx.column(coll.firstChild?.to ?? coll.from);
	if (coll.name !== "List" || inReaderConditional(coll)) return collIndent;

	// The forms before the line, not one the line starts with.
	const before = forms(coll).filter((node) => node.to <= pos);
	// zloc's index.
	const index = before.filter((node) => node.name !== "Discard").length;
	// cljfmt's `list-indent`: align with the form after the head, or one
	// column past the opener before there is an argument to align with.
	const listIndent = index > 1 ? cx.column(before[1].from) : collIndent;
	// cljfmt's `inner-indent` result: two columns past the opener of the
	// list (three past `#` in `#(...)`).
	const innerIndent = cx.column(coll.from) + 2;
	const head = headName(cx, coll);

	const apply = (key: string | RegExp, spec: Spec): number | null => {
		if (spec.kind === "block") {
			if (!matches(key, head)) return null;
			if (index <= spec.index) return listIndent;
			// cljfmt's `nth-form`, counting `#_` forms. Past the forms before
			// the line, it is zloc itself, which starts the line.
			const arg = before[spec.index + 1];
			return !arg || firstInLine(cx, arg) ? innerIndent : listIndent;
		}
		if (index < 1) return null;
		let top: SyntaxNode = coll;
		let container = coll;
		for (let depth = spec.depth; depth > 0; depth--) {
			const step = up(container);
			if (!step) return null;
			top = step.element;
			container = step.coll;
		}
		if (!matches(key, headName(cx, container))) return null;
		if (spec.index !== undefined) {
			if (spec.depth === 0) return null;
			const at = elements(container).findIndex((e) => e.from === top.from && e.to === top.to);
			if (at !== spec.index + 1) return null;
		}
		return innerIndent;
	};

	for (const [key, specs] of SORTED_INDENTS) {
		for (const spec of specs) {
			const result = apply(key, spec);
			if (result !== null) return result;
		}
	}
	return listIndent;
}

/** The Clojure pack's indentation service. */
export const clojureIndent = indentService.of(clojureIndentation);

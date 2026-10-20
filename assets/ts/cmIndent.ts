import {
	ensureSyntaxTree,
	getIndentation,
	IndentContext,
	indentService,
	indentUnit,
	type Language,
	LanguageSupport,
} from "@codemirror/language";
import { type Compartment, EditorState, type Extension, Prec, type Text } from "@codemirror/state";

/** The text of `source` above its line `line` (1-based), split the way
 *  the server cuts the editor's seed from it: it ends with a line break,
 *  unless empty. */
export function textAbove(source: string, line: number): string {
	return source
		.split("\n")
		.slice(0, line - 1)
		.map((l) => `${l}\n`)
		.join("");
}

/** How the editor indents a new line. Clojure indents by its rules as if
 *  the editor's lines sat below `above`, when they are lines of a file.
 *  Other languages keep the line's indentation: their rules see only the
 *  editor's lines, cut from the code around them, and misjudge it. */
export function indentation(language: string, above: string | undefined, support: Compartment): Extension {
	if (language !== "clojure") return Prec.high(indentService.of(() => null));
	return above === undefined ? [] : formIndentation(above, support);
}

/** The part of `above` from the start of the top-level form still open
 *  at its end, or "" when none is: a line's indentation depends on no
 *  other text in the file. */
export function openForm(above: string, language: Language): string {
	const last = language.parser.parse(above).topNode.lastChild;
	// An unclosed form runs to the end of the text; a closed one ends at
	// its closer, before `above`'s final line break.
	return last && last.to === above.length ? above.slice(last.from) : "";
}

/** The fields CodeMirror's commands pass in an IndentContext's options.
 *  They are internal to `@codemirror/language`, so read with a cast. */
interface IndentOptions {
	overrideIndentation?: (pos: number) => number;
	simulateBreak?: number;
	simulateDoubleBreak?: boolean;
}

/** Indentation computed as if the editor's lines sat below `above`: the
 *  language's rules run over the open form `above` ends in + the editor's
 *  text, so a line inside a function the editor holds only part of
 *  indents as it would in the file. `language` holds the editor's
 *  language support; until it loads, the editor's default applies. */
function formIndentation(above: string, language: Compartment): Extension {
	let form: string | null = null;
	// Indent-on-input asks several times per keystroke; reuse the parse
	// until the text changes.
	let cache: { doc: Text; state: EditorState } | null = null;
	return Prec.high(
		indentService.of((cx, pos) => {
			const support = language.get(cx.state);
			if (!(support instanceof LanguageSupport)) return undefined;
			form ??= openForm(above, support.language);
			const offset = form.length;
			if (cache?.doc !== cx.state.doc) {
				const doc = form + cx.state.doc.toString();
				const created = EditorState.create({
					doc,
					extensions: [support, indentUnit.of(cx.state.facet(indentUnit)), EditorState.tabSize.of(cx.state.tabSize)],
				});
				ensureSyntaxTree(created, doc.length, 1000);
				// The state keeps the tree it was created with; an update
				// takes the finished parse.
				cache = { doc: cx.state.doc, state: created.update({}).state };
			}
			const options = (cx as unknown as { options: IndentOptions }).options;
			const override = options.overrideIndentation;
			const shadow = new IndentContext(cache.state, {
				simulateBreak: options.simulateBreak === undefined ? undefined : options.simulateBreak + offset,
				simulateDoubleBreak: options.simulateDoubleBreak,
				overrideIndentation: override && ((p) => override(p - offset)),
			});
			return getIndentation(shadow, pos + offset);
		}),
	);
}

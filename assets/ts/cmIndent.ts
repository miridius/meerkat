import {
	ensureSyntaxTree,
	getIndentation,
	IndentContext,
	indentService,
	indentUnit,
} from "@codemirror/language";
import { type Compartment, EditorState, type Extension, Prec, Text } from "@codemirror/state";

/** The file's text around the lines a suggestion editor holds: `before`
 *  ends with a line break and `after` starts with one, unless empty. */
export interface FileContext {
	before: string;
	after: string;
}

/** The text of `source` around its lines `start..end` (1-based,
 *  inclusive), split the way the server cuts the editor's seed from it. */
export function anchorContext(source: string, start: number, end: number): FileContext {
	const lines = source.split("\n");
	return {
		before: lines
			.slice(0, start - 1)
			.map((line) => `${line}\n`)
			.join(""),
		after: lines
			.slice(end)
			.map((line) => `\n${line}`)
			.join(""),
	};
}

/** The indent unit `text` is written in: a tab when more lines start
 *  with one than step in by spaces, else the commonest step of 2 to 8
 *  spaces between consecutive lines (the smaller on a tie). Smaller steps
 *  are alignment, as in Clojure. Null when the text has none. */
export function detectIndentUnit(text: string): string | null {
	let tabs = 0;
	let previous = 0;
	const steps = new Map<number, number>();
	for (const line of text.split("\n")) {
		if (line.trim() === "") continue;
		if (line.startsWith("\t")) {
			tabs++;
			continue;
		}
		const width = line.length - line.trimStart().length;
		const step = width - previous;
		if (step >= 2 && step <= 8) steps.set(step, (steps.get(step) ?? 0) + 1);
		previous = width;
	}
	let best: number | null = null;
	let bestCount = 0;
	let votes = 0;
	for (const [step, count] of steps) {
		votes += count;
		if (count > bestCount || (count === bestCount && best !== null && step < best)) {
			best = step;
			bestCount = count;
		}
	}
	if (tabs > votes) return "\t";
	return best === null ? null : " ".repeat(best);
}

/** The fields CodeMirror's commands pass in an IndentContext's options.
 *  They are internal to `@codemirror/language`, so read with a cast. */
interface IndentOptions {
	overrideIndentation?: (pos: number) => number;
	simulateBreak?: number;
	simulateDoubleBreak?: boolean;
}

/** Indentation computed as if the editor's lines sat in the whole file:
 *  the language's rules run over `context.before` + the editor's text +
 *  `context.after`, so a line inside a function the editor holds only part
 *  of indents as it would in the file. `language` holds the editor's
 *  language support; without one, the editor's default applies. */
export function contextIndentation(context: FileContext, language: Compartment): Extension {
	// CodeMirror counts each line break as one character, `\r\n` included.
	const offset = Text.of(context.before.split(/\r\n?|\n/)).length;
	// Parsing the file again for each Enter is cheap next to typing, but
	// indent-on-input asks several times per keystroke; reuse the parse
	// until the text or the language changes.
	let cache: { doc: Text; support: Extension; state: EditorState } | null = null;
	return Prec.high(
		indentService.of((cx, pos) => {
			const support = language.get(cx.state);
			if (!support || (Array.isArray(support) && support.length === 0)) return undefined;
			if (cache?.doc !== cx.state.doc || cache.support !== support) {
				const doc = context.before + cx.state.doc.toString() + context.after;
				const created = EditorState.create({
					doc,
					extensions: [support, indentUnit.of(cx.state.facet(indentUnit)), EditorState.tabSize.of(cx.state.tabSize)],
				});
				ensureSyntaxTree(created, doc.length, 1000);
				// The state keeps the tree it was created with; an update
				// takes the finished parse.
				cache = { doc: cx.state.doc, support, state: created.update({}).state };
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

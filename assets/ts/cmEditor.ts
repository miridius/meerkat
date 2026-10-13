import { indentWithTab } from "@codemirror/commands";
import { HighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { Compartment, EditorState, type Extension, Prec } from "@codemirror/state";
import { EditorView, keymap } from "@codemirror/view";
import { tags as t } from "@lezer/highlight";
import { variantColors } from "@rose-pine/palette";
import { basicSetup } from "codemirror";
import { getLoadedLanguage, preloadLanguages } from "./cmLang.js";
import { rulerBackground } from "./rulers.js";

/** Rose Pine Moon — a dark-medium variant that reads well inside the
 *  app's existing dark chrome. Colors come from `@rose-pine/palette`
 *  so the hex values stay in sync with the upstream palette. */
const p = variantColors.moon;
const c = {
	base: `#${p.base.hex}`,
	surface: `#${p.surface.hex}`,
	overlay: `#${p.overlay.hex}`,
	muted: `#${p.muted.hex}`,
	subtle: `#${p.subtle.hex}`,
	text: `#${p.text.hex}`,
	love: `#${p.love.hex}`,
	gold: `#${p.gold.hex}`,
	rose: `#${p.rose.hex}`,
	pine: `#${p.pine.hex}`,
	foam: `#${p.foam.hex}`,
	iris: `#${p.iris.hex}`,
	highlightLow: `#${p.highlightLow.hex}`,
	highlightMed: `#${p.highlightMed.hex}`,
	highlightHigh: `#${p.highlightHigh.hex}`,
};

/** A palette color at the given opacity. */
function alpha(color: { rgb: number[] }, opacity: number): string {
	return `rgba(${color.rgb.join(", ")}, ${opacity})`;
}

const RULER_COLOR = alpha(p.highlightHigh, 0.9);

/** Rulers after `columns`, measured from the start of the text
 *  (`.cm-line` pads it 6px). They are the content's background, so they
 *  span its full height and scroll with the text. */
function rulersTheme(columns: number[]): Extension {
	// Each `EditorView.theme` call adds a stylesheet rule, so build one
	// per column list rather than one per redraw.
	const key = columns.join(",");
	let theme = rulersThemes.get(key);
	if (!theme) {
		theme = EditorView.theme({
			".cm-content": { backgroundImage: rulerBackground(columns, "6px", RULER_COLOR) },
		});
		rulersThemes.set(key, theme);
	}
	return theme;
}
const rulersThemes = new Map<string, Extension>();

/** Holds each editor's rulers, so a settings change redraws them. */
const rulers = new Compartment();

/** Redraw an open editor's rulers after `columns`. */
export function setCmRulers(view: EditorView, columns: number[]): void {
	view.dispatch({ effects: rulers.reconfigure(rulersTheme(columns)) });
}

/** Chrome theme — all the non-syntax UI: background, gutters, cursor,
 *  selection, active-line, bracket-match, search, autocompletion panels.
 *  Paired with `rosePineHighlight` below which handles syntax tokens. */
const rosePineChrome = EditorView.theme(
	{
		"&": {
			color: c.text,
			backgroundColor: c.base,
			fontSize: "0.85rem",
		},
		".cm-content": {
			caretColor: c.text,
			fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
			// Keeps a ruler at the end of the longest line clear of the
			// editor's border when scrolled right.
			paddingRight: "1ch",
		},
		"&.cm-focused": { outline: "none" },
		// A 2px gold caret: the 1px default in a pastel tone was easy to
		// lose among the code.
		".cm-cursor, .cm-dropCursor": { borderLeft: `2px solid ${c.gold}`, marginLeft: "-1px" },
		// CodeMirror paints `.cm-selectionBackground` in a layer BEHIND
		// the text, so every background over it (active line, matches)
		// is translucent below. The selection stays visible, dimmer,
		// while the editor is unfocused.
		".cm-selectionBackground": {
			backgroundColor: `${alpha(p.iris, 0.25)} !important`,
		},
		"&.cm-focused .cm-selectionBackground": {
			backgroundColor: `${alpha(p.iris, 0.4)} !important`,
		},
		".cm-content ::selection": {
			backgroundColor: alpha(p.iris, 0.4),
		},
		// Only a focused editor marks the caret's line, so an unfocused
		// one doesn't look as if it holds the caret.
		".cm-activeLine": { backgroundColor: "transparent" },
		"&.cm-focused .cm-activeLine": { backgroundColor: alpha(p.text, 0.05) },
		".cm-activeLineGutter": { backgroundColor: "transparent" },
		"&.cm-focused .cm-activeLineGutter": { backgroundColor: c.highlightLow, color: c.text },
		".cm-gutters": {
			backgroundColor: c.base,
			color: c.muted,
			borderRight: `1px solid ${c.overlay}`,
		},
		// Bracket marks are fills, not outlines: a box beside the caret
		// read as a second caret.
		".cm-matchingBracket, &.cm-focused .cm-matchingBracket": {
			color: c.foam,
			backgroundColor: alpha(p.foam, 0.25),
		},
		".cm-nonmatchingBracket, &.cm-focused .cm-nonmatchingBracket": {
			color: c.love,
			backgroundColor: alpha(p.love, 0.25),
		},
		".cm-selectionMatch": { backgroundColor: alpha(p.foam, 0.15) },
		".cm-searchMatch": {
			backgroundColor: c.highlightMed,
			outline: `1px solid ${c.gold}`,
		},
		".cm-searchMatch.cm-searchMatch-selected": {
			backgroundColor: c.gold,
			color: c.base,
		},
		".cm-tooltip": {
			backgroundColor: c.overlay,
			border: `1px solid ${c.highlightHigh}`,
			color: c.text,
		},
		".cm-tooltip-autocomplete > ul > li[aria-selected]": {
			backgroundColor: c.highlightMed,
			color: c.text,
		},
		".cm-panels": {
			backgroundColor: c.overlay,
			color: c.text,
		},
		".cm-panels-bottom": { borderTop: `1px solid ${c.highlightHigh}` },
		".cm-panels-top": { borderBottom: `1px solid ${c.highlightHigh}` },
		".cm-foldPlaceholder": {
			backgroundColor: c.overlay,
			border: `1px solid ${c.highlightHigh}`,
			color: c.subtle,
		},
	},
	{ dark: true },
);

/** Syntax token colors — follows the Rose Pine editor-token convention
 *  (see https://rosepinetheme.com/palette). Variables stay on `text`
 *  so they blend into prose; load-bearing tokens (keywords, functions,
 *  types, strings) each get their own color so the eye can scan. */
const rosePineHighlight = HighlightStyle.define([
	{ tag: t.comment, color: c.muted, fontStyle: "italic" },
	{ tag: t.lineComment, color: c.muted, fontStyle: "italic" },
	{ tag: t.blockComment, color: c.muted, fontStyle: "italic" },
	{ tag: t.docComment, color: c.muted, fontStyle: "italic" },
	{ tag: [t.keyword, t.controlKeyword, t.modifier, t.operatorKeyword], color: c.pine },
	{ tag: [t.string, t.special(t.string), t.regexp], color: c.gold },
	{ tag: [t.number, t.bool, t.null, t.atom], color: c.iris },
	{ tag: [t.function(t.variableName), t.function(t.propertyName)], color: c.rose },
	{ tag: [t.definition(t.variableName), t.definition(t.propertyName)], color: c.text },
	{ tag: [t.variableName, t.propertyName], color: c.text },
	{ tag: [t.typeName, t.className, t.namespace], color: c.foam },
	{ tag: [t.tagName, t.heading], color: c.foam, fontWeight: "bold" },
	{ tag: [t.attributeName, t.attributeValue], color: c.iris },
	{ tag: [t.punctuation, t.separator, t.operator], color: c.subtle },
	{ tag: [t.bracket, t.squareBracket, t.paren, t.brace, t.angleBracket], color: c.subtle },
	{ tag: [t.meta, t.annotation, t.processingInstruction], color: c.iris },
	{ tag: [t.link, t.url], color: c.foam, textDecoration: "underline" },
	{ tag: t.emphasis, fontStyle: "italic" },
	{ tag: t.strong, fontWeight: "bold" },
	{ tag: t.strikethrough, textDecoration: "line-through" },
	{ tag: t.invalid, color: c.love },
	{ tag: t.labelName, color: c.love },
	{ tag: [t.constant(t.variableName), t.standard(t.variableName)], color: c.gold },
	{ tag: [t.self, t.literal], color: c.love },
]);

export interface CmEditorOptions {
	/** Initial contents of the editor. */
	doc: string;
	/** Language id (Shiki-style, e.g. "rust", "clojure"). The matching
	 *  CodeMirror language pack, if there is one, joins the editor once
	 *  it has loaded; until then, or without one, the editor renders as
	 *  plain text + bracket matching. */
	language: string;
	/** Columns to draw a ruler after; `setCmRulers` changes them later. */
	rulerColumns: number[];
	/** Fires on every doc change with the new full text. */
	onChange: (value: string) => void;
	/** Fires on Ctrl/Cmd+Enter. Used as the form's submit shortcut. */
	onSubmit: () => void;
	/** Fires on Escape. Used as the form's cancel shortcut. */
	onCancel?: () => void;
}

/** Mount a CodeMirror 6 editor into `parent` with this repo's standard
 *  extension set — `basicSetup` (history, line numbers, syntax highlight,
 *  bracket matching + auto-close, indent-on-input, search, autocomplete,
 *  multi-cursor, active line highlight, selection-match highlight) plus
 *  Tab-indents-selection, Rose Pine Moon theming, rulers, and the
 *  language's pack. Lines don't wrap, so the rulers sit at true columns.
 *
 *  Returns the EditorView; destroy it with `.destroy()` on unmount. */
export function createCmEditor(parent: HTMLElement, options: CmEditorOptions): EditorView {
	const language = new Compartment();
	const extensions: Extension[] = [
		basicSetup,
		language.of(getLoadedLanguage(options.language) ?? []),
		rosePineChrome,
		rulers.of(rulersTheme(options.rulerColumns)),
		syntaxHighlighting(rosePineHighlight),
		// Tab indents the selection, Shift+Tab dedents — overrides the
		// default "move focus" behaviour for Tab inside the editor.
		keymap.of([indentWithTab]),
		// Form-level shortcuts (submit / cancel) need `Prec.high` so they
		// beat basicSetup's defaultKeymap, which binds Mod-Enter to
		// `insertBlankLine` and Escape to `simplifySelection` — both of
		// those return true and would shadow our handlers without the
		// explicit precedence bump.
		Prec.high(
			keymap.of([
				{
					key: "Mod-Enter",
					preventDefault: true,
					run: () => {
						options.onSubmit();
						return true;
					},
				},
				{
					key: "Escape",
					run: () => {
						// If no cancel handler was wired in, let CodeMirror's
						// default Escape behaviour (simplifySelection / exit
						// focus) run instead of swallowing the keystroke.
						if (!options.onCancel) return false;
						options.onCancel();
						return true;
					},
				},
			]),
		),
		EditorView.updateListener.of((update) => {
			if (update.docChanged) {
				options.onChange(update.state.doc.toString());
			}
		}),
	];

	const view = new EditorView({
		state: EditorState.create({ doc: options.doc, extensions }),
		parent,
	});
	// A pack still loading joins the editor when it arrives, so the
	// first editor opened for a language is highlighted too.
	if (!getLoadedLanguage(options.language)) {
		void preloadLanguages([options.language]).then(() => {
			const support = getLoadedLanguage(options.language);
			// Not gated on the DOM being attached: an inline form's row is
			// detached while the diff re-renders, and a destroyed view
			// ignores the update.
			if (support) {
				view.dispatch({ effects: language.reconfigure(support) });
			}
		});
	}
	return view;
}

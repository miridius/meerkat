import { indentWithTab } from "@codemirror/commands";
import type { LanguageSupport } from "@codemirror/language";
import { HighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { EditorState, type Extension, Prec } from "@codemirror/state";
import { EditorView, keymap } from "@codemirror/view";
import { tags as t } from "@lezer/highlight";
import { variantColors } from "@rose-pine/palette";
import { basicSetup } from "codemirror";
import { getLoadedLanguage } from "./cmLang.js";

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
		},
		"&.cm-focused": { outline: "none" },
		".cm-cursor, .cm-dropCursor": { borderLeftColor: c.rose },
		// CodeMirror paints `.cm-selectionBackground` BEHIND the
		// content layer. Rose-pine's `highlightMed` (#44415a) over
		// `base` (#232136) is too low-contrast to read as a
		// selection at all — use a translucent iris tint instead so
		// the highlight actually shows.
		"&.cm-focused .cm-selectionBackground, .cm-selectionBackground": {
			backgroundColor: "rgba(196, 167, 231, 0.35) !important",
		},
		".cm-content ::selection": {
			backgroundColor: "rgba(196, 167, 231, 0.35)",
		},
		".cm-activeLine": { backgroundColor: c.highlightLow },
		".cm-activeLineGutter": { backgroundColor: c.highlightLow, color: c.text },
		".cm-gutters": {
			backgroundColor: c.base,
			color: c.muted,
			borderRight: `1px solid ${c.overlay}`,
		},
		".cm-matchingBracket, &.cm-focused .cm-matchingBracket": {
			color: c.gold,
			outline: `1px solid ${c.gold}`,
		},
		".cm-nonmatchingBracket": {
			color: c.love,
			outline: `1px solid ${c.love}`,
		},
		".cm-selectionMatch": { backgroundColor: c.highlightMed },
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
	/** Language id (Shiki-style, e.g. "rust", "clojure"). When the
	 *  matching CodeMirror language pack has been preloaded via
	 *  `preloadLanguages`, its LanguageSupport slots into the editor;
	 *  otherwise the editor renders as plain text + bracket matching. */
	language: string;
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
 *  line wrapping, Tab-indents-selection, Rose Pine Moon theming, and the
 *  provided language pack if one is loaded.
 *
 *  Returns the EditorView; destroy it with `.destroy()` on unmount. */
export function createCmEditor(parent: HTMLElement, options: CmEditorOptions): EditorView {
	const langSupport: LanguageSupport | undefined = getLoadedLanguage(options.language);

	const extensions: Extension[] = [
		basicSetup,
		EditorView.lineWrapping,
		rosePineChrome,
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

	if (langSupport) extensions.push(langSupport);

	const view = new EditorView({
		state: EditorState.create({ doc: options.doc, extensions }),
		parent,
	});
	return view;
}

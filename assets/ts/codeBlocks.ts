import { highlighter as lowlight } from "@git-diff-view/lowlight";
import type { DiffHighlighter } from "@git-diff-view/shiki";
import { hastToHtml } from "shiki";
import { DIFF_THEME, sharedHighlighter } from "./diffHighlighter";

/** Highlights a comment body's fenced code blocks, such as a
 *  suggestion's, the way the diff highlights code
 *  (docs/features/inline-comments.md). */

type Highlighter = Pick<DiffHighlighter, "getAST" | "hasRegisteredCurrentLang">;
type Hast = Parameters<typeof hastToHtml>[0];

/** The highlighted inner HTML for a fenced block's `<code>`, from the
 *  engine the diff would pick: shiki when it has `lang` loaded, else
 *  lowlight. Null when the engine returns no tree. */
export function highlightedCode(
	code: string,
	lang: string,
	shiki: Highlighter | null,
	fallback: Highlighter = lowlight,
): string | null {
	if (shikiHas(shiki, lang)) {
		// shiki wraps the lines in a <pre><code> the block already has.
		const lines = (shiki.getAST(code, undefined, lang) as Hast | undefined)?.children[0]?.children[0]?.children;
		return lines ? hastToHtml({ type: "root", children: lines } as Hast) : null;
	}
	const ast = fallback.getAST(code, undefined, lang) as Hast | undefined;
	return ast ? hastToHtml(ast) : null;
}

// shiki throws for a language it hasn't loaded rather than answering no.
function shikiHas(shiki: Highlighter | null, lang: string): boolean {
	try {
		return !!shiki?.hasRegisteredCurrentLang(lang);
	} catch {
		return false;
	}
}

/** Highlight every `<pre><code class="language-…">` under `root` in
 *  place, under the diff's syntax classes so its theme colours them. */
export function highlightCodeBlocks(root: HTMLElement, shiki: Highlighter | null): void {
	for (const code of root.querySelectorAll<HTMLElement>('pre > code[class^="language-"]')) {
		if (code.classList.contains("diff-line-syntax-raw")) continue;
		const lang = code.classList[0].slice("language-".length);
		const html = highlightedCode(code.textContent ?? "", lang, shiki);
		if (html === null) continue;
		code.innerHTML = html;
		code.classList.add("diff-line-syntax-raw");
		const pre = code.parentElement as HTMLElement;
		pre.classList.add("diff-tailwindcss-wrapper");
		pre.dataset.theme = DIFF_THEME;
	}
}

/** `highlightCodeBlocks` with the diff's highlighter, once it's ready. */
export function highlightCodeBlocksWhenReady(root: HTMLElement): void {
	sharedHighlighter.then((h) => highlightCodeBlocks(root, h));
}

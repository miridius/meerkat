import type { DiffHighlighter } from "@git-diff-view/shiki";
import { getDiffViewHighlighter, highlighterReady } from "@git-diff-view/shiki";

// Eagerly create ONE shiki engine with the languages we expect to
// hit in a typical review. shiki warns at 10 instances, so the diff
// and the comment code blocks share this module-level singleton.
// Languages outside this list (or shiki bundles like `puml`) fall back
// to lowlight, in the diff and in codeBlocks.ts alike.
const PRELOAD_LANGS = [
	"typescript",
	"tsx",
	"javascript",
	"jsx",
	"json",
	"html",
	"css",
	"markdown",
	"bash",
	"python",
	"go",
	"ruby",
	"rust",
	"c",
	"cpp",
	"java",
	"kotlin",
	"swift",
	"yaml",
	"sql",
	"xml",
	"elixir",
	"erlang",
	"clojure",
	"lisp",
	"diff",
];

// @git-diff-view skips syntax highlighting entirely for files longer
// than maxLineToIgnoreSyntax (a per-highlighter guard against shiki
// tokenize cost on huge files). The default is 2000 lines, which real
// hand-written files exceed — a 2.3k-line test file rendered with no
// highlighting at all. Raise it to a bound that still protects
// against generated monsters but never bites on code a human wrote.
const MAX_SYNTAX_LINES = 20_000;

// Importing @git-diff-view/shiki also builds its default engine, which
// lacks languages above such as clojure and elixir, and whichever
// engine finishes last is the one it highlights with. Once both are
// built, asking for ours again selects it.
export const sharedHighlighter: Promise<DiffHighlighter | null> = Promise.all([
	highlighterReady,
	getDiffViewHighlighter(PRELOAD_LANGS as never[]),
])
	.then(() => getDiffViewHighlighter(PRELOAD_LANGS as never[]))
	.then((h) => {
		// Guarded separately from the engine-init catch below: a setter
		// failure (adapter shape drift on a dependency bump) must not
		// null out the whole highlighter — files under the library's
		// 2000-line default would still highlight fine.
		try {
			h.setMaxLineToIgnoreSyntax(MAX_SYNTAX_LINES);
		} catch (e) {
			console.warn(
				"diffHighlighter: setMaxLineToIgnoreSyntax failed; files over the library's 2000-line default will render unhighlighted",
				e,
			);
		}
		return h as DiffHighlighter;
	})
	.catch((e) => {
		console.warn("diffHighlighter: shiki highlighter init failed; falling back to lowlight", e);
		return null;
	});

// The diff's theme, which the Clojure hover popup's source and comment
// code blocks follow.
export const DIFF_THEME = "dark";

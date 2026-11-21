import { describe, expect, test } from "bun:test";
import { highlightedCode } from "./codeBlocks";

const span = (cls: string, text: string) => ({
	type: "element",
	tagName: "span",
	properties: { className: [cls] },
	children: [{ type: "text", value: text }],
});

// What shiki's getAST returns: the lines inside a <pre><code>. Like
// shiki, it throws for a language it hasn't loaded.
const shiki = (registered: string[]) => ({
	hasRegisteredCurrentLang: (lang: string) => {
		if (!registered.includes(lang)) throw new Error(`Language \`${lang}\` not found`);
		return true;
	},
	getAST: (code: string) => ({
		type: "root",
		children: [
			{
				type: "element",
				tagName: "pre",
				properties: {},
				children: [{ type: "element", tagName: "code", properties: {}, children: [span("line", code)] }],
			},
		],
	}),
});

// What lowlight's getAST returns: bare spans.
const fallback = {
	hasRegisteredCurrentLang: () => true,
	getAST: (code: string) => ({ type: "root", children: [span("hljs-keyword", code)] }),
};

const none = { hasRegisteredCurrentLang: () => true, getAST: () => undefined };

describe("highlightedCode", () => {
	test("takes shiki's lines, without its pre and code, when shiki has the language", () => {
		expect(highlightedCode("(inc 1)", "clojure", shiki(["clojure"]) as never, fallback as never)).toBe(
			'<span class="line">(inc 1)</span>',
		);
	});

	test("falls back to lowlight when shiki lacks the language or isn't ready", () => {
		const out = '<span class="hljs-keyword">echo 1;</span>';
		expect(highlightedCode("echo 1;", "php", shiki(["clojure"]) as never, fallback as never)).toBe(out);
		expect(highlightedCode("echo 1;", "php", null, fallback as never)).toBe(out);
	});

	test("escapes the code", () => {
		expect(highlightedCode("<b>", "php", null, fallback as never)).toBe(
			'<span class="hljs-keyword">&#x3C;b></span>',
		);
	});

	test("is null when the engine returns no tree", () => {
		expect(highlightedCode("x", "clojure", { ...none, hasRegisteredCurrentLang: () => true } as never)).toBeNull();
		expect(highlightedCode("x", "php", null, none as never)).toBeNull();
	});

	test("lowlight, the default fallback, colours a language shiki doesn't preload", () => {
		expect(highlightedCode("<?php echo 1;", "php", null)).toContain('class="hljs-keyword"');
	});
});

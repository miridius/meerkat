import { describe, expect, test } from "bun:test";
import { languageFor } from "./languageFor";

// The blocking dependency gate forces linguist-languages / shiki
// bumps, and resolution changes from a bump are invisible to the
// e2e suite (its only token assertion is one .clj file).
describe("languageFor", () => {
	test("shiki alias wins shared linguist extensions", () => {
		// .ts is also Qt Linguist XML, .jsx is plain JavaScript in
		// linguist, .h is C/C++/Objective-C — the alias keeps the
		// reader-expected grammar.
		expect(languageFor("a.ts")).toBe("typescript");
		expect(languageFor("a.tsx")).toBe("tsx");
		expect(languageFor("a.jsx")).toBe("jsx");
		expect(languageFor("a.rs")).toBe("rust");
		expect(languageFor("a.clj")).toBe("clojure");
		expect(languageFor("a.md")).toBe("markdown");
	});

	test("linguist fills in extensions shiki has no alias for", () => {
		expect(languageFor("a.ex")).toBe("elixir");
		expect(languageFor("a.exs")).toBe("elixir");
		expect(languageFor("a.cljs")).toBe("clojure");
		expect(languageFor("a.h")).toBe("c");
	});

	test("overrides map languages shiki can't name", () => {
		expect(languageFor("deps.edn")).toBe("clojure");
	});

	test("filename lookup beats extension guessing", () => {
		expect(languageFor("Dockerfile")).toBe("docker");
		expect(languageFor("Makefile")).toBe("make");
		// Filename-identified but grammarless: plaintext, never the
		// extension fallback's wrong guess (.mod → XML).
		expect(languageFor("go.mod")).toBe("plaintext");
		expect(languageFor("go.sum")).toBe("plaintext");
	});

	test("case-insensitive, path-stripping", () => {
		expect(languageFor("Foo.RS")).toBe("rust");
		expect(languageFor("src/deep/path/README.MD")).toBe("markdown");
	});

	test("extension-less and dotfiles are plaintext", () => {
		expect(languageFor("README")).toBe("plaintext");
		expect(languageFor(".gitignore")).toBe("plaintext");
	});

	test("unknown extensions fall through raw for the lowlight engine", () => {
		expect(languageFor("a.zzz9")).toBe("zzz9");
	});

	test("hostile names can't reach Object.prototype members", () => {
		expect(languageFor("x.constructor")).toBe("constructor");
		expect(languageFor("x.__proto__")).toBe("__proto__");
	});
});

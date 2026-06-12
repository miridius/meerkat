import * as linguist from "linguist-languages";
import { bundledLanguagesInfo } from "shiki";

/** File-name → language id for both highlighting consumers: the
 *  shiki diff highlighter and the CodeMirror suggestion editor (whose
 *  loader table in `cmLang.ts` keys on shiki ids). GitHub Linguist's
 *  languages.yml (the `linguist-languages` data package) maps
 *  extension/filename → language; shiki's bundled-language registry
 *  validates that the engine has a grammar for the result.
 *
 *  The `shiki` dependency is pinned to the same major as
 *  `@git-diff-view/shiki`'s — a second copy would validate ids
 *  against a different language set than the engine runs. */

type LinguistLanguage = {
	name: string;
	aliases?: string[];
	extensions?: string[];
	filenames?: string[];
};

/** Every shiki id and alias → its canonical id ("clj" → "clojure"). */
const shikiIdByAlias = new Map<string, string>();
for (const info of bundledLanguagesInfo) {
	shikiIdByAlias.set(info.id, info.id);
	for (const alias of info.aliases ?? []) shikiIdByAlias.set(alias, info.id);
}

/** Linguist languages indexed by extension (lowercased, with dot) and
 *  by exact filename (lowercased). Extensions are shared by multiple
 *  languages (.h → C / C++ / Objective-C); candidates are kept sorted
 *  by name so resolution below is deterministic. */
const linguistByExtension = new Map<string, LinguistLanguage[]>();
const linguistByFilename = new Map<string, LinguistLanguage>();
for (const lang of Object.values(linguist) as LinguistLanguage[]) {
	for (const ext of lang.extensions ?? []) {
		const key = ext.toLowerCase();
		const list = linguistByExtension.get(key) ?? [];
		list.push(lang);
		list.sort((a, b) => a.name.localeCompare(b.name));
		linguistByExtension.set(key, list);
	}
	for (const fileName of lang.filenames ?? []) {
		linguistByFilename.set(fileName.toLowerCase(), lang);
	}
}

/** Meerkat-level choices the datasets can't make for us: cases where
 *  Linguist names a language shiki has no grammar for, but a closely
 *  related grammar highlights it well. Null prototype so a hostile
 *  file name like `x.constructor` can't resolve to an inherited
 *  Object member. */
const OVERRIDES: Record<string, string> = Object.assign(Object.create(null), {
	edn: "clojure",
});

function shikiIdForLinguist(lang: LinguistLanguage): string | undefined {
	for (const candidate of [lang.name.toLowerCase(), ...(lang.aliases ?? [])]) {
		const id = shikiIdByAlias.get(candidate);
		if (id) return id;
	}
	return undefined;
}

/** Resolve a repo-relative file name to a canonical shiki language id,
 *  "plaintext" for extension-less files, or the raw extension when
 *  nothing matches (the lowlight fallback engine may still know it). */
export function languageFor(fileName: string): string {
	const base = (fileName.split("/").pop() ?? "").toLowerCase();

	const byName = linguistByFilename.get(base);
	if (byName) {
		const id = shikiIdForLinguist(byName);
		if (id) return id;
		// Linguist identified the file by NAME (go.mod → "Go Module");
		// when no grammar exists for that language, plain text beats
		// the extension fallback's wrong guess (.mod → XML).
		return "plaintext";
	}

	const dot = base.lastIndexOf(".");
	if (dot <= 0) return "plaintext";
	const ext = base.slice(dot + 1);

	if (OVERRIDES[ext]) return OVERRIDES[ext];

	// The bare extension is itself often a shiki alias (rs, py, clj,
	// md, ts…) — and where it is, it disambiguates shared linguist
	// extensions the way a reader would expect (.ts → TypeScript, not
	// Qt's XML dialect; .jsx keeps its JSX-aware grammar rather than
	// collapsing into linguist's plain JavaScript).
	const direct = shikiIdByAlias.get(ext);
	if (direct) return direct;

	for (const lang of linguistByExtension.get("." + ext) ?? []) {
		const id = shikiIdForLinguist(lang);
		if (id) return id;
	}

	return ext;
}

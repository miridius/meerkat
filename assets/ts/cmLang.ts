import type { LanguageSupport } from "@codemirror/language";

/** Dynamic-import factories for every CodeMirror 6 language pack we
 *  ship. Keyed by the language id the backend emits from
 *  `Meerkat.Git.language_for/1` (extension-keyed string lookup with
 *  an `other -> other` fallthrough, so e.g. `.rs` keys `"rust"`;
 *  extensions not in the table arrive as the raw extension string).
 *
 *  Factories are async so Vite can split each language pack into its
 *  own chunk — we only pay the download cost for languages actually
 *  used in a given review. See `preloadLanguages` for the batched
 *  preload path that warms these up at review-load time. */
const LANGUAGE_LOADERS: Record<string, () => Promise<LanguageSupport>> = {
	javascript: () => import("@codemirror/lang-javascript").then((m) => m.javascript()),
	typescript: () =>
		import("@codemirror/lang-javascript").then((m) => m.javascript({ typescript: true })),
	jsx: () => import("@codemirror/lang-javascript").then((m) => m.javascript({ jsx: true })),
	tsx: () =>
		import("@codemirror/lang-javascript").then((m) =>
			m.javascript({ typescript: true, jsx: true }),
		),
	rust: () => import("@codemirror/lang-rust").then((m) => m.rust()),
	python: () => import("@codemirror/lang-python").then((m) => m.python()),
	html: () => import("@codemirror/lang-html").then((m) => m.html()),
	css: () => import("@codemirror/lang-css").then((m) => m.css()),
	scss: () => import("@codemirror/lang-css").then((m) => m.css()),
	less: () => import("@codemirror/lang-css").then((m) => m.css()),
	json: () => import("@codemirror/lang-json").then((m) => m.json()),
	markdown: () => import("@codemirror/lang-markdown").then((m) => m.markdown()),
	sql: () => import("@codemirror/lang-sql").then((m) => m.sql()),
	xml: () => import("@codemirror/lang-xml").then((m) => m.xml()),
	yaml: () => import("@codemirror/lang-yaml").then((m) => m.yaml()),
	go: () => import("@codemirror/lang-go").then((m) => m.go()),
	java: () => import("@codemirror/lang-java").then((m) => m.java()),
	cpp: () => import("@codemirror/lang-cpp").then((m) => m.cpp()),
	c: () => import("@codemirror/lang-cpp").then((m) => m.cpp()),
	php: () => import("@codemirror/lang-php").then((m) => m.php()),
	vue: () => import("@codemirror/lang-vue").then((m) => m.vue()),
	clojure: () => import("@nextjournal/lang-clojure").then((m) => m.clojure()),
};

/** Resolved language packs keyed by language id. Populated by
 *  `preloadLanguages`; readable synchronously by the editor setup so
 *  the CodeMirror instance can drop the right LanguageSupport into
 *  its extension list at mount time. */
const loaded: Map<string, LanguageSupport> = new Map();

/** Languages we started loading but haven't resolved yet — so a
 *  second call for the same id doesn't kick off a duplicate import. */
const pending: Map<string, Promise<LanguageSupport | undefined>> = new Map();

/** Kick off parallel dynamic imports for every supported language in
 *  `ids`. Unsupported ids are silently ignored (the editor falls back
 *  to plain text + bracket matching for those). Returns a promise
 *  that resolves when every supported language has loaded — callers
 *  can await it, but don't have to; late mounts will just see the
 *  still-empty slot and render unhighlighted until the preload
 *  completes. */
export async function preloadLanguages(ids: readonly string[]): Promise<void> {
	const unique = Array.from(new Set(ids)).filter((id) => id && LANGUAGE_LOADERS[id]);
	await Promise.all(
		unique.map(async (id) => {
			if (loaded.has(id)) return;
			let promise = pending.get(id);
			if (!promise) {
				promise = LANGUAGE_LOADERS[id]()
					.then((support) => {
						loaded.set(id, support);
						return support;
					})
					.catch((err) => {
						// A missing sub-dep or a broken dynamic import shouldn't
						// kill the whole preload — the editor falls back to
						// plain-text behaviour when the slot stays empty.
						console.warn(`Failed to load CodeMirror language '${id}':`, err);
						return undefined;
					})
					.finally(() => {
						// Drop the pending entry either way so a transient
						// failure (network blip, stale chunk) gets another
						// attempt on the next `preloadLanguages` call instead
						// of being locked in as "already tried, gave up".
						// `loaded` already guards the happy-path dedup.
						pending.delete(id);
					});
				pending.set(id, promise);
			}
			await promise;
		}),
	);
}

/** Return the already-preloaded language pack for `id`, or `undefined`
 *  if it isn't loaded (either unsupported or still pending). The
 *  editor uses this at mount time — it doesn't block the form on a
 *  preload that's still in flight; it just opens without syntax
 *  highlighting and the next open will have it. */
export function getLoadedLanguage(id: string): LanguageSupport | undefined {
	return loaded.get(id);
}

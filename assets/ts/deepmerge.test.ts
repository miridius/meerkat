import { describe, expect, test } from "bun:test";
import { createRequire } from "node:module";

type Merged = { [key: string]: Merged };

// The deepmerge the Svelte Vite plugin loads, with patches/deepmerge.patch
// applied (GHSA-gcqx-w48m-w2h4).
const merge: (target: unknown, source: unknown) => Merged = createRequire(
	import.meta.resolve("@sveltejs/vite-plugin-svelte"),
)("deepmerge");

const P = '{"__proto__":{"isAdmin":true}}';

describe("patched deepmerge", () => {
	test("a __proto__ key does not set the prototype of what it returns", () => {
		const nullProto = Object.assign(Object.create(null), { debug: false });
		const cases = [
			merge(nullProto, JSON.parse(P)),
			merge({ session: null }, JSON.parse(`{"session":${P}}`)).session,
			merge(JSON.parse(P), { verbose: true }),
			merge({ list: [] }, JSON.parse(`{"list":[${P}]}`)).list[0],
		];
		for (const merged of cases) {
			expect(Object.getPrototypeOf(merged)).toBe(Object.prototype);
			expect(merged.isAdmin).toBeUndefined();
		}
	});

	test("a constructor key is dropped", () => {
		const merged = merge(Object.create(null), JSON.parse('{"constructor":{"prototype":{"x":1}}}'));
		expect(Object.hasOwn(merged, "constructor")).toBe(false);
	});

	test("other keys still merge deeply", () => {
		expect(merge({ a: { b: 1 }, debug: false }, { a: { c: 2 } })).toEqual({
			a: { b: 1, c: 2 },
			debug: false,
		});
	});
});

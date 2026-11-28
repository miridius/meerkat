// Clojure reviews for the hover and go to definition specs: a staged
// review of Clojure files, and pointing at a symbol the way a reviewer
// does.

import { spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Page } from "@playwright/test";
import { makeFixture } from "./fixture";

/** A staged review of `files` changed from `base`, whose user has
 *  linted it with clj-kondo. */
export function stagedReview(base: Record<string, string>, files: Record<string, string>) {
	const fixture = makeFixture({ files: {} });
	const write = (all: Record<string, string>) => {
		for (const [path, body] of Object.entries(all)) {
			mkdirSync(join(fixture.dir, path, ".."), { recursive: true });
			writeFileSync(join(fixture.dir, path), body);
			fixture.git("add", path);
		}
	};
	write(base);
	fixture.git("commit", "-qm", "base");
	write(files);
	// The user's own clj-kondo run, whose cache names each namespace's file.
	mkdirSync(join(fixture.dir, ".clj-kondo"));
	spawnSync("clj-kondo", ["--lint", "src"], { cwd: fixture.dir });
	return fixture;
}

/** The middle of the first character of the `nth` `word` in a code
 *  cell of `side`, or of the open file view for "view", and that
 *  character's box's top and bottom. */
export async function symbolPoint(page: Page, side: "old" | "new" | "view", word: string, nth = 1) {
	// Unified view's rows show a side by the line numbers they carry.
	const cells = {
		old: "td.diff-line-old-content, tr:not(:has([data-line-new-num])) > td.diff-line-content",
		new: "td.diff-line-new-content, tr:has([data-line-new-num]) > td.diff-line-content",
		view: '[data-test="clj-file-view"] [data-clj-line]',
	}[side];
	const point = await page.evaluate(
		({ cells, word, nth }) => {
			let left = nth;
			for (const cell of document.querySelectorAll(cells)) {
				const raw = cell.querySelector(".diff-line-syntax-raw, .diff-line-content-raw");
				if (!raw) continue;
				const walker = document.createTreeWalker(raw, NodeFilter.SHOW_TEXT);
				for (let node = walker.nextNode(); node; node = walker.nextNode()) {
					const at = node.textContent?.indexOf(word) ?? -1;
					if (at < 0 || --left > 0) continue;
					const range = document.createRange();
					range.setStart(node, at);
					range.setEnd(node, at + 1);
					const r = range.getBoundingClientRect();
					return { x: r.left + r.width / 2, y: r.top + r.height / 2, top: r.top, bottom: r.bottom };
				}
			}
			return null;
		},
		{ cells, word, nth },
	);
	if (!point) throw new Error(`no ${word} on the ${side} side`);
	return point;
}

/** Rests the pointer on the first character of the `nth` `word` (see
 *  `symbolPoint`), and returns that character's box. */
export async function restOn(page: Page, side: "old" | "new" | "view", word: string, nth = 1) {
	const point = await symbolPoint(page, side, word, nth);
	await page.mouse.move(point.x, point.y);
	return point;
}

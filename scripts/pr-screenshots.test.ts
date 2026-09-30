import { describe, expect, test } from "bun:test";
import { type Shot, section, withScreenshots } from "./pr-screenshots.ts";

const shot = (code: Shot["code"], name: string, caption: string): Shot => ({
	code,
	name,
	file: `${code}-${name}.png`,
	caption,
});

describe("section", () => {
	test("shows each caption above its image", () => {
		expect(section([shot("head", "footer", "The footer links each form")])).toBe(
			"<!-- pr-screenshots:start -->\n## Screenshots\n\n" +
				"The footer links each form\n\n![The footer links each form](./head-footer.png)\n" +
				"<!-- pr-screenshots:end -->",
		);
	});

	test("pairs base and head shots of one name as Before and After, in head order", () => {
		const out = section([
			shot("base", "gutter", "Buttons on the left"),
			shot("base", "removed", "Only before"),
			shot("head", "new", "Only after"),
			shot("head", "gutter", "Buttons on the right"),
		]);
		const body = out.split("\n").slice(3, -1).join("\n");
		expect(body).toBe(
			[
				"Only after\n\n![Only after](./head-new.png)",
				"**Before:** Buttons on the left\n\n![Buttons on the left](./base-gutter.png)\n\n" +
					"**After:** Buttons on the right\n\n![Buttons on the right](./head-gutter.png)",
				"Only before\n\n![Only before](./base-removed.png)",
			].join("\n\n"),
		);
	});

	test("keeps markdown in the caption but not in the alt text", () => {
		expect(section([shot("head", "x", "The `open_forms.ex L32–37` [link]\nwraps")])).toContain(
			"The `open_forms.ex L32–37` [link]\nwraps\n\n![The open_forms.ex L32–37 link wraps](./head-x.png)",
		);
	});
});

describe("withScreenshots", () => {
	const shots = [shot("head", "x", "X")];

	test("replaces the section an earlier run added", () => {
		const body = `Intro\n\n${section([shot("head", "old", "Old")])}\n\n_Written by a model_\n`;
		expect(withScreenshots(body, shots)).toBe(`Intro\n\n${section(shots)}\n\n_Written by a model_\n`);
	});

	test("puts a new section before a trailing attribution line", () => {
		expect(withScreenshots("Intro\n\n_Written by a model_\n", shots)).toBe(
			`Intro\n\n${section(shots)}\n\n_Written by a model_\n`,
		);
	});

	test("appends a new section when there is no attribution line", () => {
		expect(withScreenshots("Intro\n", shots)).toBe(`Intro\n\n${section(shots)}\n`);
	});
});

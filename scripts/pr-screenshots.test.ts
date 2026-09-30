import { describe, expect, test } from "bun:test";
import { type Shot, section, withScreenshots } from "./pr-screenshots.ts";

const shot = (code: Shot["code"], name: string, caption?: string): Shot => ({
	code,
	name,
	file: `${code}-${name}.png`,
	caption,
});

describe("section", () => {
	test("shows a caption, when given, above its image", () => {
		expect(section([shot("head", "footer", "the form links"), shot("head", "split")])).toBe(
			"<!-- pr-screenshots:start -->\n## Screenshots\n\n" +
				"the form links\n\n![footer](./head-footer.png)\n\n![split](./head-split.png)\n" +
				"<!-- pr-screenshots:end -->",
		);
	});

	test("pairs base and head shots of one name as Before and After, in head order", () => {
		const out = section([
			shot("base", "gutter"),
			shot("base", "removed", "Only before"),
			shot("head", "new"),
			shot("head", "gutter", "now on the right"),
		]);
		const body = out.split("\n").slice(3, -1).join("\n");
		expect(body).toBe(
			[
				"![new](./head-new.png)",
				"**Before**\n\n![Before](./base-gutter.png)\n\n" +
					"**After:** now on the right\n\n![After](./head-gutter.png)",
				"Only before\n\n![removed](./base-removed.png)",
			].join("\n\n"),
		);
	});
});

describe("withScreenshots", () => {
	const shots = [shot("head", "x")];

	test("replaces the section an earlier run added", () => {
		const body = `Intro\n\n${section([shot("head", "old")])}\n\n_Written by a model_\n`;
		expect(withScreenshots(body, shots)).toBe(`Intro\n\n${section(shots)}\n\n_Written by a model_\n`);
	});

	test("moves text written after an earlier section above the new one", () => {
		const body = `Intro\n\n${section([shot("head", "old")])}\n\n**Notes**\n- more\n\n_Written by a model_\n`;
		expect(withScreenshots(body, shots)).toBe(
			`Intro\n\n**Notes**\n- more\n\n${section(shots)}\n\n_Written by a model_\n`,
		);
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

// CI builds from source the tools .github/toolchain.env pins that the
// macOS runner lacks or has too old: GNU bash, since its bash 3.2 lacks
// what bin/meerkat-attach uses, and Graphviz, whose dot PlantUML lays
// diagrams out with. It fetches the release's files, checks them together
// against <TOOL>_SHA256, and installs to the PREFIX argument.
//
//   bun scripts/build-tool.ts bash|graphviz PREFIX

import { createHash } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { $ } from "bun";
import { gnuBashFiles, graphvizFiles } from "./toolchain";

type Recipe = {
	key: string;
	files: (version: string) => string[];
	// Unpacks the downloaded FILES into WORK; returns the source dir.
	unpack: (version: string, files: string[], work: string) => Promise<string>;
	configure: string[];
};

const RECIPES: Record<string, Recipe> = {
	bash: {
		key: "GNU_BASH",
		files: gnuBashFiles,
		unpack: async (version, [tarball, ...patches], work) => {
			await $`tar -xzf ${tarball} -C ${work}`;
			const src = join(work, `bash-${version.split(".").slice(0, 2).join(".")}`);
			for (const patch of patches) await $`patch -s -p0 -d ${src} < ${patch}`;
			return src;
		},
		configure: ["--without-bash-malloc"],
	},
	// dot with only the core renderers, which write PlantUML's SVG. With
	// PKG_CONFIG=false the build finds none of the runner's optional
	// libraries, so it does not vary with what the image has installed.
	graphviz: {
		key: "GRAPHVIZ",
		files: graphvizFiles,
		unpack: async (version, [tarball], work) => {
			await $`tar -xJf ${tarball} -C ${work}`;
			return join(work, `graphviz-${version}`);
		},
		configure: [
			...["swig", "sharp", "go", "guile", "java", "lua", "perl", "php", "python", "python3", "r", "ruby", "tcl", "man-pdfs"].map(
				(f) => `--disable-${f}`,
			),
			...[
				"x", "expat", "devil", "webp", "poppler", "rsvg", "ghostscript", "pangocairo", "lasi",
				"freetype2", "gdk", "gdk-pixbuf", "gtk", "gtkgl", "gtkglext", "gts", "ann", "glade", "qt",
				"libgd", "glut", "smyrna", "aalib",
			].map((w) => `--without-${w}`),
		],
	},
};

const [tool = "", prefix] = process.argv.slice(2);
const recipe = RECIPES[tool];
const version = recipe && process.env[`${recipe.key}_VERSION`];
const expected = recipe && process.env[`${recipe.key}_SHA256`];
if (!recipe || !prefix || !version || !expected) {
	console.error(
		"usage: <TOOL>_VERSION=... <TOOL>_SHA256=... bun scripts/build-tool.ts bash|graphviz PREFIX",
	);
	process.exit(2);
}

const work = mkdtempSync(join(tmpdir(), `build-${tool}-`));
try {
	const hash = createHash("sha256");
	const local: string[] = [];
	for (const [i, url] of recipe.files(version).entries()) {
		const path = join(work, `${i}-${url.split("/").at(-1)}`);
		await $`curl -fsSLo ${path} ${url}`;
		hash.update(await Bun.file(path).bytes());
		local.push(path);
	}
	const actual = hash.digest("hex");
	if (actual !== expected) {
		console.error(`scripts/build-tool.ts: ${tool} ${version} hashes to ${actual}, not ${expected}.`);
		process.exitCode = 1;
	} else {
		const src = await recipe.unpack(version, local, work);
		await $`./configure --prefix=${prefix} ${recipe.configure}`.cwd(src).env({ ...process.env, PKG_CONFIG: "false" }).quiet();
		await $`make -j${navigator.hardwareConcurrency}`.cwd(src).quiet();
		await $`make install`.cwd(src).quiet();
		console.log(`built ${tool} ${version} into ${prefix}`);
	}
} finally {
	rmSync(work, { recursive: true, force: true });
}

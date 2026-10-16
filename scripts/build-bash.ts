// CI builds the GNU bash that .github/toolchain.env pins, since the macOS
// runner's bash 3.2 lacks what bin/meerkat-attach uses. It fetches the
// release and its official patches, checks them together against
// GNU_BASH_SHA256, and installs to the PREFIX argument.
//
//   bun scripts/build-bash.ts PREFIX

import { createHash } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { $ } from "bun";
import { gnuBashFiles } from "./toolchain";

const prefix = process.argv[2];
const version = process.env.GNU_BASH_VERSION;
const expected = process.env.GNU_BASH_SHA256;
if (!prefix || !version || !expected) {
	console.error(
		"usage: GNU_BASH_VERSION=... GNU_BASH_SHA256=... bun scripts/build-bash.ts PREFIX",
	);
	process.exit(2);
}

const work = mkdtempSync(join(tmpdir(), "gnu-bash-"));
try {
	const files = gnuBashFiles(version);
	const hash = createHash("sha256");
	const local: string[] = [];
	for (const [i, url] of files.entries()) {
		const path = join(work, String(i));
		await $`curl -fsSLo ${path} ${url}`;
		hash.update(await Bun.file(path).bytes());
		local.push(path);
	}
	const actual = hash.digest("hex");
	if (actual !== expected) {
		console.error(`scripts/build-bash.ts: bash ${version} hashes to ${actual}, not ${expected}.`);
		process.exitCode = 1;
	} else {
		const [tarball, ...patches] = local;
		await $`tar -xzf ${tarball} -C ${work}`;
		const src = join(work, `bash-${version.split(".").slice(0, 2).join(".")}`);
		for (const patch of patches) await $`patch -s -p0 -d ${src} < ${patch}`;
		await $`./configure --prefix=${prefix} --without-bash-malloc`.cwd(src).quiet();
		await $`make -j${navigator.hardwareConcurrency}`.cwd(src).quiet();
		await $`make install`.cwd(src).quiet();
		console.log(`built GNU bash ${version} into ${prefix}`);
	}
} finally {
	rmSync(work, { recursive: true, force: true });
}

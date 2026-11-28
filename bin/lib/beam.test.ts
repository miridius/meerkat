import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { anyNewer } from "./beam.ts";

test("anyNewer, like find, follows no symlink", () => {
	const root = mkdtempSync(join(tmpdir(), "meerkat-beam-"));
	try {
		mkdirSync(join(root, "lib"));
		writeFileSync(join(root, "newer"), "");
		symlinkSync("..", join(root, "lib/cycle"));
		symlinkSync("../newer", join(root, "lib/newer"));
		const old = new Date(1000);
		utimesSync(join(root, "lib"), old, old);
		const than = Date.now() - 60_000;
		utimesSync(join(root, "newer"), new Date(), new Date());
		expect(anyNewer(root, ["lib"], than)).toBe(true);
		// The links themselves are new; dated old, nothing under lib is newer.
		for (const link of ["lib/cycle", "lib/newer"])
			Bun.spawnSync(["touch", "-h", "-t", "197001020000", join(root, link)]);
		expect(anyNewer(root, ["lib"], than)).toBe(false);
	} finally {
		rmSync(root, { recursive: true, force: true });
	}
});

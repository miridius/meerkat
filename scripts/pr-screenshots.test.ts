import { expect, test } from "bun:test";
import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Shot } from "./pr-screenshots.ts";

// A stand-in for `gh` that logs each call and answers the repo-id
// lookup and the uploads.
const FAKE_GH = `#!/bin/sh
printf '%s\\n' "$*" >> "$GH_LOG"
case "$*" in
  "api repos/{owner}/{repo} -q .id") echo 42 ;;
  *uploads.github.com*) echo "https://example.test/$(printf '%s' "$*" | sed 's/.*name=\\([^&]*\\).*/\\1/')" ;;
  *) exit 1 ;;
esac
`;

test("attach uploads each shot and prints its URL and caption, without editing the PR", () => {
	const dir = mkdtempSync(join(tmpdir(), "pr-screenshots-test-"));
	const gh = join(dir, "gh");
	writeFileSync(gh, FAKE_GH);
	chmodSync(gh, 0o755);
	const shots: Shot[] = [
		{ code: "base", name: "gutter", file: "base-gutter.png" },
		{ code: "head", name: "gutter", file: "head-gutter.png", caption: "now on the right" },
	];
	writeFileSync(join(dir, "shots.json"), JSON.stringify(shots));
	for (const s of shots) writeFileSync(join(dir, s.file), "png");
	const log = join(dir, "gh.log");

	const proc = Bun.spawnSync(["bun", join(import.meta.dir, "pr-screenshots.ts"), "attach", "--pr", "7", "--out", dir], {
		env: { ...process.env, PATH: `${dir}:${process.env.PATH}`, GH_LOG: log },
	});

	expect(proc.stderr.toString()).toBe("");
	expect(proc.stdout.toString()).toBe(
		"base-gutter.png https://example.test/base-gutter.png\n" +
			"head-gutter.png https://example.test/head-gutter.png now on the right\n",
	);
	const calls = readFileSync(log, "utf8").trim().split("\n");
	expect(calls).toHaveLength(3);
	expect(calls.every((c) => c.startsWith("api "))).toBe(true);
	expect(calls[1]).toContain(`--input ${join(dir, "base-gutter.png")}`);
});

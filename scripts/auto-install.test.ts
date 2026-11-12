import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { plan, withoutVars } from "./auto-install";

describe("plan", () => {
	test("installs on main", () => {
		expect(plan("main")).toEqual({ install: true });
	});

	test("says why it skips any other branch, or a HEAD git cannot resolve", () => {
		expect(plan("feature")).toEqual({
			install: false,
			message: "meerkat auto-install: HEAD=feature (not main); skipping.",
		});
		expect(plan("")).toEqual({ install: false, message: "meerkat auto-install: couldn't resolve HEAD; skipping." });
	});
});

describe("withoutVars", () => {
	test("drops each variable named on its own line", () => {
		expect(withoutVars({ GIT_DIR: "d", GIT_INDEX_FILE: "i", GIT_EDITOR: "e", PATH: "/bin" }, "GIT_DIR\nGIT_INDEX_FILE\n")).toEqual({
			GIT_EDITOR: "e",
			PATH: "/bin",
		});
	});
});

// The real scripts/auto-install.ts in a throwaway repo, with the
// environment git gives a post-checkout hook. scripts/install.sh and `mix`
// are stubs that log each run and the git variables mix sees.
describe("auto-install.ts", () => {
	let base: string;
	let repo: string;
	let env: Record<string, string | undefined>;

	const git = (cwd: string, ...args: string[]) => {
		const result = Bun.spawnSync(["git", ...args], { cwd, env: gitEnv(), stderr: "inherit" });
		if (result.exitCode !== 0) throw new Error(`git ${args.join(" ")} failed`);
	};
	const gitEnv = () => ({
		...process.env,
		GIT_CONFIG_GLOBAL: join(import.meta.dir, "../test/support/test.gitconfig"),
		GIT_CONFIG_NOSYSTEM: "1",
	});

	beforeAll(() => {
		base = mkdtempSync(join(tmpdir(), "meerkat-auto-install-"));
		repo = join(base, "repo");
		const log = join(base, "log");
		mkdirSync(join(repo, "scripts"), { recursive: true });
		copyFileSync(join(import.meta.dir, "auto-install.ts"), join(repo, "scripts/auto-install.ts"));
		writeFileSync(join(repo, "scripts/install.sh"), `echo install.sh >> '${log}'\n`);
		git(base, "init", "-q", "--template=", "--initial-branch=main", repo);
		git(repo, "add", ".");
		git(repo, "-c", "user.email=t@t.t", "-c", "user.name=t", "commit", "-q", "-m", "base");

		const mix = join(base, "shim/mix");
		mkdirSync(dirname(mix));
		writeFileSync(
			mix,
			`#!/usr/bin/env bash
echo "MIX_ENV=\${MIX_ENV:-} mix $*" >> '${log}'
env | grep -E '^GIT_(DIR|INDEX_FILE|WORK_TREE)=' | sed 's/^/  leaked /' >> '${log}'
exit 0
`,
		);
		chmodSync(mix, 0o755);

		// What git exports to a hook it runs in this checkout, with the
		// user's env, which sets no MIX_ENV.
		env = {
			...gitEnv(),
			PATH: `${dirname(mix)}:${process.env.PATH}`,
			GIT_DIR: join(repo, ".git"),
			GIT_INDEX_FILE: join(repo, ".git/index"),
			MIX_ENV: undefined,
		};
	});

	afterAll(() => rmSync(base, { recursive: true, force: true }));

	const autoInstall = () => {
		rmSync(join(base, "log"), { force: true });
		const result = Bun.spawnSync([process.execPath, "scripts/auto-install.ts"], { cwd: repo, env, stderr: "pipe" });
		return { status: result.exitCode, stderr: result.stderr.toString() };
	};
	const logLines = async () => {
		const log = Bun.file(join(base, "log"));
		return (await log.exists()) ? (await log.text()).split("\n").filter((l) => l !== "") : [];
	};

	test("on main, installs and then refreshes the dev and test envs' deps and builds", async () => {
		expect(autoInstall().status).toBe(0);
		expect(await logLines()).toEqual([
			"install.sh",
			"MIX_ENV= mix deps.get",
			"MIX_ENV=dev mix compile",
			"MIX_ENV=test mix compile",
		]);
	});

	test("off main, does nothing", async () => {
		git(repo, "switch", "-q", "-c", "feature");
		const run = autoInstall();
		expect(run).toEqual({ status: 0, stderr: "meerkat auto-install: HEAD=feature (not main); skipping.\n" });
		expect(await logLines()).toEqual([]);
	});
});

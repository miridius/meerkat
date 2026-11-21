import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, readlinkSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fakeGit } from "./fake-git";
import { gitDeps, hookInput, type Io, setup, tail } from "./setup-worktree";

const MIX_LOCK = `%{
  "bandit": {:hex, :bandit, "1.12.5", "x", [:mix], [], "hexpm", "y"},
  "muex": {:git, "https://example.com/muex.git", "abc", [ref: "abc"]},
}
`;

test("reads the hook input's event and cwd", () => {
	expect(hookInput('{"hook_event_name":"SubagentStart","cwd":"/w"}')).toEqual({ event: "SubagentStart", cwd: "/w" });
	expect(hookInput('{"cwd":1}')).toEqual({ event: "", cwd: "" });
	expect(hookInput("null")).toEqual({ event: "", cwd: "" });
	expect(hookInput("not json")).toEqual({ event: "", cwd: "" });
});

test("lists mix.lock's git deps", () => {
	expect(gitDeps(MIX_LOCK)).toEqual(["muex"]);
});

test("keeps a command's last lines", () => {
	expect(tail("a\nb\nc\n", 2)).toBe("b\nc");
	expect(tail("a\n", 20)).toBe("a");
});

// setup on a temp checkout, with git, the commands it runs, and the lock
// stood in for.
describe("setup", () => {
	let dir: string;
	let checkout: string;
	let calls: string[];
	let status: Record<string, number>;
	let gitAnswers: Record<string, string>;
	let mise: boolean;

	const io = (): Io => ({
		git: fakeGit(gitAnswers).g,
		run: (cmd, cwd, env) => {
			const line = cmd.join(" ");
			if (line === "mise env --json") return { status: 0, out: '{"MISE":"1"}' };
			calls.push(`${line}${env.MISE ? " (mise env)" : ""}`);
			expect(cwd).toBe(checkout);
			const code = status[cmd[0]] ?? 0;
			return { status: code, out: Array.from({ length: 25 }, (_, i) => `${cmd[0]} line ${i + 1}`).join("\n") };
		},
		has: (tool) => tool === "mise" && mise,
		lock: (path) => calls.push(`lock ${path}`),
	});
	const hook = (cwd = checkout) => setup(JSON.stringify({ hook_event_name: "SubagentStart", cwd }), io(), {});
	const write = (path: string, text = "") => {
		mkdirSync(dirname(join(checkout, path)), { recursive: true });
		writeFileSync(join(checkout, path), text);
	};
	const installDeps = () => {
		mkdirSync(join(checkout, "deps/bandit"), { recursive: true });
		mkdirSync(join(checkout, "deps/muex/.git"), { recursive: true });
		write("node_modules/.modules.yaml");
	};
	const LOCK = "lock /repo/.git/meerkat-setup.lock";

	beforeEach(() => {
		dir = mkdtempSync(join(tmpdir(), "meerkat-setup-"));
		checkout = join(dir, "checkout");
		write("mix.lock", MIX_LOCK);
		write("pnpm-lock.yaml", "lockfileVersion: '9.0'\n");
		calls = [];
		status = {};
		mise = false;
		gitAnswers = {
			[`-C ${checkout} rev-parse --path-format=absolute --git-path meerkat-setup.lock`]: "/repo/.git/meerkat-setup.lock\n",
			[`-C ${checkout} rev-parse --path-format=absolute --git-common-dir`]: `${checkout}/.git\n`,
			[`-C ${checkout} rev-parse --show-toplevel`]: `${checkout}\n`,
		};
	});
	afterEach(() => rmSync(dir, { recursive: true, force: true }));

	test("a checkout with its deps installed runs nothing and prints nothing", () => {
		installDeps();
		expect(hook()).toBe("");
		expect(calls).toEqual([LOCK]);
	});

	test("a checkout with no deps installs both, holding the lock", () => {
		expect(hook()).toBe("");
		expect(calls).toEqual([LOCK, "mix deps.get", "pnpm install --frozen-lockfile --prefer-offline"]);
	});

	test("a git dep without its nested repo fetches Mix deps", () => {
		installDeps();
		rmSync(join(checkout, "deps/muex/.git"), { recursive: true });
		hook();
		expect(calls).toEqual([LOCK, "mix deps.get"]);
	});

	test("node_modules without pnpm's state installs JS deps", () => {
		installDeps();
		rmSync(join(checkout, "node_modules/.modules.yaml"));
		hook();
		expect(calls).toEqual([LOCK, "pnpm install --frozen-lockfile --prefer-offline"]);
	});

	describe("a checkout pinning its tools in .tool-versions", () => {
		beforeEach(() => {
			write(".tool-versions", "erlang 29.1.2\n");
			write("scripts/setup-toolchain.ts");
		});

		test("installs the toolchain, then the deps in mise's env", () => {
			mise = true;
			write("node_modules/.modules.yaml");
			expect(hook()).toBe("");
			expect(calls).toEqual([LOCK, "bun scripts/setup-toolchain.ts", "mix deps.get (mise env)"]);
		});

		test("without mise, installs the deps in the hook's env", () => {
			write("node_modules/.modules.yaml");
			hook();
			expect(calls).toEqual([LOCK, "bun scripts/setup-toolchain.ts", "mix deps.get"]);
		});
	});

	test("a failed step is reported with its last 20 lines, and the setup goes on", () => {
		status.mix = 1;
		const out = JSON.parse(hook());
		const lines = Array.from({ length: 20 }, (_, i) => `mix line ${i + 6}`).join("\n");
		expect(out).toEqual({
			hookSpecificOutput: {
				hookEventName: "SubagentStart",
				additionalContext: `Dependency setup failed. \`mix deps.get\` failed in ${checkout}:\n${lines}\n`,
			},
		});
		expect(calls).toEqual([LOCK, "mix deps.get", "pnpm install --frozen-lockfile --prefer-offline"]);
	});

	test("a linked worktree gets back the _build symlinks its copy lacks", () => {
		const main = join(dir, "main");
		gitAnswers[`-C ${checkout} rev-parse --path-format=absolute --git-common-dir`] = `${main}/.git\n`;
		const links: Record<string, string> = {
			"_build/dev/lib/file_system/priv": "../../../../deps/file_system/priv",
			"_build/dev/lib/phoenix/priv": "../../../../deps/phoenix/priv",
			"_build/test/lib/meerkat/priv": "../../../../priv",
			"_build/test/lib/stream_data/priv": "../../../../deps/stream_data/priv",
		};
		for (const [link, target] of Object.entries(links)) {
			mkdirSync(dirname(join(main, link)), { recursive: true });
			symlinkSync(target, join(main, link));
		}
		installDeps();
		mkdirSync(join(checkout, "_build/dev/lib/file_system"), { recursive: true });
		mkdirSync(join(checkout, "_build/test/lib/meerkat/priv"), { recursive: true });
		// A link already in the worktree, dangling until its dep is fetched.
		mkdirSync(join(checkout, "_build/dev/lib/phoenix"), { recursive: true });
		symlinkSync("../../../../deps/elsewhere", join(checkout, "_build/dev/lib/phoenix/priv"));

		expect(hook()).toBe("");

		const readLink = (link: string) => readlinkSync(join(checkout, link));
		expect(readLink("_build/dev/lib/file_system/priv")).toBe("../../../../deps/file_system/priv");
		expect(readLink("_build/dev/lib/phoenix/priv")).toBe("../../../../deps/elsewhere");
		expect(() => readLink("_build/test/lib/meerkat/priv")).toThrow("EINVAL");
		expect(() => readLink("_build/test/lib/stream_data/priv")).toThrow("ENOENT");
	});

	test("a directory that is not a meerkat checkout, or not in git, is left alone", () => {
		const other = join(dir, "other");
		mkdirSync(other);
		expect(hook(other)).toBe("");
		gitAnswers = {};
		expect(hook()).toBe("");
		expect(calls).toEqual([]);
	});
});

// The real script, three at once in one
// throwaway checkout, with stub `mix` and `pnpm` that log each run: the
// lock lets only the first fetch the Mix deps, and the stub pnpm's failure
// reaches each run's output.
test("hooks starting at once in one checkout take turns", async () => {
	const dir = mkdtempSync(join(tmpdir(), "meerkat-setup-"));
	try {
		const checkout = join(dir, "checkout");
		const bin = join(dir, "bin");
		const log = join(dir, "log");
		mkdirSync(bin);
		// A git hook's GIT_DIR and friends would point git at this repo.
		const env: Record<string, string | undefined> = {
			...process.env,
			PATH: `${bin}:${process.env.PATH}`,
			GIT_CONFIG_GLOBAL: join(import.meta.dir, "../test/support/test.gitconfig"),
			GIT_CONFIG_NOSYSTEM: "1",
		};
		for (const name of ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"]) delete env[name];
		expect(Bun.spawnSync(["git", "init", "-q", checkout], { env }).exitCode).toBe(0);
		writeFileSync(join(checkout, "mix.lock"), MIX_LOCK);
		writeFileSync(join(checkout, "pnpm-lock.yaml"), "");
		const stub = (name: string, body: string) => {
			writeFileSync(join(bin, name), `#!/usr/bin/env bash\necho "${name} $*" >> '${log}'\n${body}\n`);
			chmodSync(join(bin, name), 0o755);
		};
		stub("mix", "sleep 1; mkdir -p deps/muex/.git");
		stub("pnpm", "echo 'pnpm says no' >&2; exit 1");

		const input = JSON.stringify({ hook_event_name: "SessionStart", cwd: checkout });
		const runs = [1, 2, 3].map(async () => {
			const p = Bun.spawn([process.execPath, join(import.meta.dir, "setup-worktree.ts")], {
				env,
				stdin: new Blob([input]),
				stdout: "pipe",
			});
			return { status: await p.exited, out: await new Response(p.stdout).text() };
		});
		const context = `Dependency setup failed. \`pnpm install --frozen-lockfile --prefer-offline\` failed in ${checkout}:\npnpm says no\n`;
		const expected = { status: 0, out: `${JSON.stringify({ hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: context } })}\n` };
		expect(await Promise.all(runs)).toEqual([expected, expected, expected]);
		expect(readFileSync(log, "utf8").trim().split("\n")).toEqual([
			"mix deps.get",
			"pnpm install --frozen-lockfile --prefer-offline",
			"pnpm install --frozen-lockfile --prefer-offline",
			"pnpm install --frozen-lockfile --prefer-offline",
		]);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

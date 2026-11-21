// Run by .claude/hooks/setup-worktree.sh, the SessionStart, SubagentStart
// and PostToolUse(EnterWorktree) hook: installs any missing toolchain, Hex
// or JS dependencies in the checkout Claude starts in or enters, before
// Claude works there, so a fresh worktree can build and test and its git
// hooks find lefthook (`pnpm install` installs it). The hook input's `cwd`
// is that checkout; CLAUDE_PROJECT_DIR stays the session's starting
// project.
//
// scripts/setup-toolchain.ts installs the Erlang, Elixir and Bun
// .tool-versions pins through mise, then Hex and rebar3 for that Elixir,
// and is quick when they are in place. mise's env then puts the pinned
// tools first on PATH for the deps.
// Mix deps count as missing when there is no deps/, or a mix.lock git dep
// has no deps/<name>/.git (the nested repo a copied deps/ lacks). mix.lock
// also lists optional deps that are never fetched, so other entries are
// not checked. JS deps count as missing when node_modules has no pnpm
// state.
// In a linked worktree, the hook also recreates each symlink under the
// main checkout's _build/ that is missing from the worktree's copy, where
// the link's parent directory exists in the worktree: Claude Code's
// .worktreeinclude copy leaves symlinks out, and Mix recreates a dep's
// priv/ link only when it recompiles that dep.
// Parallel subagents can start in one checkout at once, so each run holds
// a per-checkout lock; the kernel drops it if the hook is killed.
// Nothing is printed when nothing is missing. A failed step is reported
// to Claude as additional context, never blocking the session.

import { closeSync, lstatSync, mkdtempSync, openSync, readdirSync, readFileSync, readlinkSync, rmSync, statSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { type Env, type Git, git } from "./checked-trees";

export type Io = {
	git: Git;
	// Runs a command in a directory, in env, giving its status and its
	// stdout and stderr together.
	run: (cmd: string[], cwd: string, env: Env) => { status: number; out: string };
	// The variables `mise env` sets in cwd, or null without mise or when it
	// fails.
	miseEnv: (cwd: string, env: Env) => Env | null;
	// Returns once this process holds the lock on the file at path.
	lock: (path: string) => void;
};

// The hook input's event name and cwd, each "" when missing.
export function hookInput(text: string): { event: string; cwd: string } {
	let input: unknown;
	try {
		input = JSON.parse(text);
	} catch {
		return { event: "", cwd: "" };
	}
	const field = (key: string) => {
		const value = (input as Record<string, unknown> | null)?.[key];
		return typeof value === "string" ? value : "";
	};
	return { event: field("hook_event_name"), cwd: field("cwd") };
}

// The names of mix.lock's git deps.
export function gitDeps(mixLock: string): string[] {
	return [...mixLock.matchAll(/^ {2}"([^"]+)": \{:git,/gm)].map((m) => m[1]);
}

// The last count lines of text.
export function tail(text: string, count: number): string {
	return text.trimEnd().split("\n").slice(-count).join("\n");
}

const stat = (path: string) => statSync(path, { throwIfNoEntry: false });
const isFile = (path: string) => stat(path)?.isFile() ?? false;
const isDir = (path: string) => stat(path)?.isDirectory() ?? false;
// True for anything at path, a dangling symlink included.
const isPresent = (path: string) => lstatSync(path, { throwIfNoEntry: false }) !== undefined;

// Every symlink under dir, not following any.
function* symlinks(dir: string): Generator<string> {
	for (const entry of readdirSync(dir, { withFileTypes: true })) {
		const path = join(dir, entry.name);
		if (entry.isSymbolicLink()) yield path;
		else if (entry.isDirectory()) yield* symlinks(path);
	}
}

// Sets up the checkout the hook input names, in env, and gives what the
// hook prints.
export function setup(input: string, io: Io, env: Env): string {
	const { event, cwd } = hookInput(input);
	if (cwd === "" || !isFile(join(cwd, "mix.lock")) || !isFile(join(cwd, "pnpm-lock.yaml"))) return "";
	const revParse = (...args: string[]) => {
		const r = io.git(["-C", cwd, "rev-parse", ...args]);
		return r.status === 0 ? r.out.trim() : null;
	};
	const lock = revParse("--path-format=absolute", "--git-path", "meerkat-setup.lock");
	if (lock === null) return "";
	io.lock(lock);

	let failures = "";
	const fail = (what: string, out: string) => {
		failures += `\`${what}\` failed in ${cwd}:\n${tail(out, 20)}\n`;
	};
	let runEnv = env;
	const run = (...cmd: string[]) => {
		const r = io.run(cmd, cwd, runEnv);
		if (r.status !== 0) fail(cmd.join(" "), r.out);
	};

	if (isFile(join(cwd, "scripts/setup-toolchain.ts"))) run("bun", "scripts/setup-toolchain.ts");
	const mise = isFile(join(cwd, ".tool-versions")) ? io.miseEnv(cwd, env) : null;
	if (mise !== null) runEnv = { ...env, ...mise };
	const deps = join(cwd, "deps");
	const mixLock = readFileSync(join(cwd, "mix.lock"), "utf8");
	if (!isDir(deps) || gitDeps(mixLock).some((name) => !stat(join(deps, name, ".git")))) {
		run("mix", "deps.get");
	}
	if (!isFile(join(cwd, "node_modules/.modules.yaml"))) {
		run("pnpm", "install", "--frozen-lockfile", "--prefer-offline");
	}

	const commonDir = revParse("--path-format=absolute", "--git-common-dir");
	const top = revParse("--show-toplevel");
	const main = commonDir === null ? null : dirname(commonDir);
	if (main !== null && top !== null && main !== top && isDir(join(main, "_build"))) {
		for (const source of symlinks(join(main, "_build"))) {
			const link = join(top, source.slice(main.length + 1));
			if (isDir(dirname(link)) && !isPresent(link)) {
				const target = readlinkSync(source);
				try {
					symlinkSync(target, link);
				} catch (e) {
					fail(`ln -s ${target} ${link}`, (e as Error).message);
				}
			}
		}
	}

	if (failures === "") return "";
	const output = { hookSpecificOutput: { hookEventName: event, additionalContext: `Dependency setup failed. ${failures}` } };
	return `${JSON.stringify(output)}\n`;
}

// Tried once a second rather than waited on: lockf(1) on an fd spins a
// core while it blocks. lockf takes the lock on the descriptor handed to
// it as fd 9, so this process holds it once lockf exits, until it exits.
// Bun opens files close-on-exec, so no command the hook runs keeps it.
function lockFile(path: string) {
	const fd = openSync(path, "w");
	const stdio = ["ignore", "ignore", "inherit", ...Array(6).fill("ignore"), fd];
	// Exit 75 means another run holds the lock.
	while (Bun.spawnSync(["lockf", "-s", "-t", "0", "9"], { stdio } as never).exitCode === 75) Bun.sleepSync(1000);
}

function runCommand(cmd: string[], cwd: string, env: Env) {
	const dir = mkdtempSync(join(tmpdir(), "meerkat-setup-"));
	try {
		const log = join(dir, "log");
		const fd = openSync(log, "w");
		let status: number;
		try {
			status = Bun.spawnSync(cmd, { cwd, env, stdin: "ignore", stdout: fd, stderr: fd }).exitCode ?? 1;
		} catch (e) {
			return { status: 127, out: (e as Error).message };
		} finally {
			closeSync(fd);
		}
		return { status, out: readFileSync(log, "utf8") };
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
}

if (import.meta.main) {
	const io: Io = {
		git,
		run: runCommand,
		miseEnv: (cwd, env) => {
			if (Bun.which("mise", { PATH: env.PATH ?? "" }) === null) return null;
			// stdout alone: mise warns on stderr, as about a pin not installed.
			const r = Bun.spawnSync(["mise", "env", "--json"], { cwd, env, stdin: "ignore", stdout: "pipe", stderr: "ignore" });
			try {
				return r.exitCode === 0 ? JSON.parse(r.stdout.toString()) : null;
			} catch {
				return null;
			}
		},
		lock: lockFile,
	};
	process.stdout.write(setup(await Bun.stdin.text(), io, process.env));
}

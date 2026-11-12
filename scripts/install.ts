// Build + install meerkat for the current host. Produces a Mix release
// under ~/.local/share/meerkat-beam/versions/<id>/ and points a
// ~/.local/share/meerkat-beam/current symlink at it, wrapped by a
// launcher at ~/.local/bin/meerkat that forwards the user's cwd via
// $MEERKAT_PWD.
//
// Versioned + symlinked so an upgrade never disturbs a running review:
// each build lands in its own immutable `versions/<id>` dir, the
// launcher resolves `current` to a concrete version AT LAUNCH, and a
// new install flips the symlink without touching the dir a live BEAM is
// reading. Old version dirs are GC'd (keep the newest few + any a
// running review is still pinned to).
//
// scripts/install.sh, which installs the Bun that runs this, is the
// entry point: `bash scripts/install.sh` (or `--force` to rebuild even
// when unchanged). The lefthook post-merge / post-checkout hooks run it
// (via scripts/auto-install.ts) whenever local `main` advances.
// Idempotent: skips the rebuild when `current` already points at this
// commit's version, the tree is clean, and the prod launcher is in place.

import {
	accessSync,
	constants,
	copyFileSync,
	existsSync,
	mkdirSync,
	mkdtempSync,
	readdirSync,
	readFileSync,
	readlinkSync,
	renameSync,
	rmSync,
	statSync,
	symlinkSync,
	writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { basename, join } from "node:path";

// How many version dirs to retain for rollback/history. A version a
// running review is still pinned to is always kept, even past this.
export const KEEP_VERSIONS = 5;

export type Paths = {
	share: string;
	bin: string;
	versions: string;
	current: string;
	wrapper: string;
	// The prod shepherd lives outside the version dirs (it re-resolves
	// `current` every spawn, so it's version-agnostic and survives GC).
	shepherd: string;
	attach: string;
};

export function installPaths(env: Record<string, string | undefined>, home: string): Paths {
	const share = env.MEERKAT_INSTALL_PREFIX || join(home, ".local/share/meerkat-beam");
	const bin = env.MEERKAT_BIN_DIR || join(home, ".local/bin");
	return {
		share,
		bin,
		versions: join(share, "versions"),
		current: join(share, "current"),
		wrapper: join(bin, "meerkat"),
		shepherd: join(share, "meerkat-shepherd"),
		attach: join(share, "meerkat-attach"),
	};
}

// Version id (a human-readable dir name; uniqueness is enforced later by
// `freeVersionDir`): the commit for a clean build, marked `-wip.<ts>` when
// built from a dirty tree so it reads as "not a pristine commit build".
export function versionId(head: string, dirty: boolean, nowSeconds: number): string {
	return head !== "" && !dirty ? head.slice(0, 12) : `${head.slice(0, 12)}-wip.${nowSeconds}`;
}

// What bash 5's `printf %q` makes of a path the launcher bakes in, so the
// launcher a bash install.sh wrote still counts as this script's: every
// printable ASCII character but letters, digits and `_./:+@%=-` is
// backslash-escaped, `#` and `~` only at the start of the word.
export function shellQuote(s: string): string {
	if (s === "") return "''";
	return s.replace(/[\n -~]/g, (c, i) => {
		if (/[A-Za-z0-9_./:+@%=-]/.test(c) || (i > 0 && (c === "#" || c === "~"))) return c;
		return c === "\n" ? "$'\\n'" : `\\${c}`;
	});
}

// The launcher is thin: it execs the shepherd, which loops the release
// BEAM, resolving `current` to a concrete version dir on each spawn so a
// review can live-restart onto a new version. The paths are baked in
// rather than hardcoded to $HOME, so a custom MEERKAT_INSTALL_PREFIX is
// honored end-to-end, and quoted as `printf %q` would, so they stay safe
// if they contain spaces.
export function launcher(currentLink: string, shepherd: string): string {
	return `#!/usr/bin/env bash
# meerkat launcher (installed by scripts/install.sh). Forwards the
# user's cwd as $MEERKAT_PWD and hands off to the shepherd.
set -euo pipefail
export MEERKAT_PWD="\${MEERKAT_PWD:-$PWD}"
export MEERKAT_CURRENT_LINK=${shellQuote(currentLink)}
SHEPHERD=${shellQuote(shepherd)}
if [[ ! -x "$SHEPHERD" ]]; then
  echo "meerkat: shepherd missing at $SHEPHERD; re-run scripts/install.sh from the meerkat repo." >&2
  exit 127
fi
exec "$SHEPHERD" "$@"
`;
}

export type InstalledState = {
	// The installed launcher's text, or null when it is missing or not
	// executable.
	wrapper: string | null;
	// The commit stamped in `current`'s version dir, or "" without one.
	stamp: string;
	releaseExecutable: boolean;
	shepherdExecutable: boolean;
	attachIsFile: boolean;
};

// Idempotency: the post-merge / post-checkout hooks fire this on every
// `main` checkout, but a rebuild takes minutes, so skip when `current` is
// already a clean build of this commit. Keyed on the commit stamp in the
// current version dir, not its name, so a forced rebuild can land in a
// fresh immutable dir without making every later run rebuild. The
// launcher must also be this script's, so any other launcher is replaced.
// Texts compare as bash's `$(...)` gives them, without trailing newlines.
export function upToDate(
	force: boolean,
	head: string,
	dirty: boolean,
	expectedLauncher: string,
	state: InstalledState,
): boolean {
	return (
		!force &&
		head !== "" &&
		!dirty &&
		state.wrapper !== null &&
		trimNewlines(state.wrapper) === trimNewlines(expectedLauncher) &&
		state.stamp === head &&
		state.releaseExecutable &&
		state.shepherdExecutable &&
		state.attachIsFile
	);
}

export const trimNewlines = (s: string) => s.replace(/\n+$/, "");

// The repo's web URL from its `origin` URL, as the toolbar chip links it.
export function repoUrl(origin: string): string {
	return origin
		.split("\n")
		.map((line) => line.replace(/^git@github\.com:/, "https://github.com/").replace(/\.git$/, ""))
		.join("\n");
}

// A version manifest baked into the release so the toolbar chip can show
// what version is running and the recent changelog. Plain newline format
// (commit, repo URL, then the last 15 first-parent subjects verbatim);
// Meerkat.Version parses the `(#N)` out of each subject. First-parent on
// `main` is one squashed commit per merged PR.
export const versionManifest = (head: string, url: string, subjects: string) => `${head}\n${url}\n${subjects}`;

// A version dir is immutable once built: a running review lazy-loads
// code/assets from it for its whole life. So never build over an existing
// dir (a `--force` rebuild of a commit that's already `current` would
// otherwise rm it out from under a review that resolved `current` to it
// mid-rebuild); take the first free `<id>` / `<id>.N` instead.
export function freeVersionDir(versions: string, id: string, exists: (path: string) => boolean): string {
	let dir = join(versions, id);
	for (let n = 1; exists(dir); n++) dir = join(versions, `${id}.${n}`);
	return dir;
}

// True when any running process, as `ps -axo command=` lists them, is
// reading `dir` (a version dir): the BEAM references it as `<dir>/...`
// (bindir, boot_var RELEASE_LIB, …), so the match is anchored on a
// trailing slash. Without it a clean-commit id is a substring of its own
// `<id>-wip.<ts>` sibling and they cross-match. Keeps GC from deleting a
// dir a live review still lazy-loads from.
export const dirInUse = (commands: string, dir: string) => commands.includes(`${dir}/`);

// The version dirs GC deletes, given every one newest first: keep the
// newest `keep`, the one just built, the `current` target, and any dir a
// running review is still pinned to.
export function gcVictims(
	newestFirst: string[],
	built: string,
	currentTarget: string,
	keep: number,
	inUse: (dir: string) => boolean,
): string[] {
	const victims: string[] = [];
	let kept = 0;
	for (const dir of newestFirst) {
		if (dir === built || dir === currentTarget) continue;
		kept++;
		if (kept <= keep || inUse(dir)) continue;
		victims.push(dir);
	}
	return victims;
}

// The version dirs under `versions`, newest first by mtime, as
// `ls -1dt versions/*/` lists them: directories, or links to them, whose
// names do not start with a dot, ties in name order.
export function versionDirs(versions: string): string[] {
	let names: string[];
	try {
		names = readdirSync(versions);
	} catch {
		return [];
	}
	const dirs: { path: string; name: string; mtime: bigint }[] = [];
	for (const name of names.filter((n) => !n.startsWith("."))) {
		const path = join(versions, name);
		try {
			const stat = statSync(path, { bigint: true });
			if (stat.isDirectory()) dirs.push({ path, name, mtime: stat.mtimeNs });
		} catch {}
	}
	dirs.sort((a, b) => (a.mtime === b.mtime ? (a.name < b.name ? -1 : 1) : a.mtime > b.mtime ? -1 : 1));
	return dirs.map((d) => d.path);
}

// The environment without git's per-repository variables. When this runs
// from the lefthook post-merge hook, GIT_DIR / GIT_WORK_TREE /
// GIT_INDEX_FILE etc are set to the *parent* meerkat repo. Left set, the
// smoke test's `git init` would re-initialise the parent repo, and `git
// commit --allow-empty -m init` would land a phantom "init" commit on the
// caller's local branch.
export function withoutGitVars(env: Record<string, string | undefined>): Record<string, string | undefined> {
	return Object.fromEntries(Object.entries(env).filter(([name]) => !name.startsWith("GIT_")));
}

type Env = Record<string, string | undefined>;

// The exit status bash gives a command that `Bun.spawnSync` reports.
function status(result: { exitCode: number | null; signalCode?: string | null }): number {
	if (result.exitCode !== null) return result.exitCode;
	const signal = result.signalCode ? constants.signals[result.signalCode as keyof typeof constants.signals] : 0;
	return 128 + (signal ?? 0);
}

// Runs `cmd` with the given env, looking it up on that env's PATH, and
// exits with its status if it fails, as `set -e` does.
function run(cmd: string[], env: Env, cwd?: string): void {
	const exe = Bun.which(cmd[0], { PATH: env.PATH ?? "" });
	if (exe === null) {
		process.stderr.write(`meerkat: ${cmd[0]}: command not found\n`);
		process.exit(127);
	}
	const result = Bun.spawnSync([exe, ...cmd.slice(1)], { env, cwd, stdio: ["inherit", "inherit", "inherit"] });
	const code = status(result);
	if (code !== 0) process.exit(code);
}

// The stdout of `cmd`, or "" when it fails, as `$(cmd 2>/dev/null || true)`.
function output(cmd: string[], env: Env): string {
	const result = Bun.spawnSync(cmd, { env, stdout: "pipe", stderr: "ignore" });
	return result.exitCode === 0 ? result.stdout.toString() : "";
}

const executable = (path: string) => {
	try {
		accessSync(path, constants.X_OK);
		return true;
	} catch {
		return false;
	}
};

const readOr = (path: string, fallback: string) => {
	try {
		return readFileSync(path, "utf8");
	} catch {
		return fallback;
	}
};

const readlinkOr = (path: string) => {
	try {
		return readlinkSync(path);
	} catch {
		return "";
	}
};

const isFile = (path: string) => {
	try {
		return statSync(path).isFile();
	} catch {
		return false;
	}
};

const psCommands = () => output(["ps", "-axo", "command="], process.env);

function install(args: string[]): void {
	process.chdir(join(import.meta.dir, ".."));
	let env: Env = { ...process.env };
	const paths = installPaths(env, homedir());
	const head = trimNewlines(output(["git", "rev-parse", "HEAD"], env));
	const dirty = output(["git", "status", "--porcelain"], env) !== "";
	const expected = launcher(paths.current, paths.shepherd);
	const currentTarget = readlinkOr(paths.current);

	const state: InstalledState = {
		wrapper: executable(paths.wrapper) ? readOr(paths.wrapper, "") : null,
		stamp: trimNewlines(readOr(join(currentTarget, "INSTALLED_COMMIT"), "")),
		releaseExecutable: executable(join(currentTarget, "bin/meerkat")),
		shepherdExecutable: executable(paths.shepherd),
		attachIsFile: isFile(paths.attach),
	};
	if (upToDate(args[0] === "--force", head, dirty, expected, state)) {
		console.log(
			`meerkat: current already built from ${head.slice(0, 12)} (clean tree); skipping. Pass --force to rebuild.`,
		);
		process.exit(0);
	}

	console.log(`meerkat: building Mix release for ${trimNewlines(output(["uname", "-sm"], env))}...`);

	// The release bundles the Erlang it is built with: with mise, the one
	// .tool-versions pins, put first on PATH whether or not mise is
	// activated in the user's shell; without it, whatever is on PATH.
	// Either way with the Hex and rebar3 .github/toolchain.env pins.
	const mise = Bun.which("mise", { PATH: env.PATH ?? "" });
	if (mise) {
		run([mise, "install", "erlang", "elixir", "bun"], env);
		const result = Bun.spawnSync([mise, "env", "--json"], { env, stdout: "pipe", stderr: "inherit" });
		const code = status(result);
		if (code !== 0) process.exit(code);
		env = { ...env, ...JSON.parse(result.stdout.toString()) };
	}
	run(["bun", "scripts/setup-toolchain.ts"], env);

	// Fetch Elixir deps first: assets/package.json pulls phoenix /
	// live_svelte / phoenix_vite JS out of deps/ via `file:` links, so
	// deps/ must exist before `pnpm install` runs.
	const prod = { ...env, MIX_ENV: "prod" };
	run(["mix", "deps.get", "--only", "prod"], prod);

	// Phoenix assets need to be built before the release packages priv/.
	// pnpm installs (the workspace covers assets/ too); bun runs the
	// build; see pnpm-workspace.yaml for why the tools are split.
	if (existsSync("assets") && statSync("assets").isDirectory()) {
		run(["pnpm", "install", "--frozen-lockfile", "--ignore-scripts"], env);
		run(["bun", "run", "build"], env, "assets");
	}

	run(["mix", "compile", "--warnings-as-errors"], prod);
	// Asset digest is mandatory for LiveView in prod: missing manifests
	// = broken UI at runtime. Run loud + fail loud.
	run(["mix", "phx.digest"], prod);
	// Nuke the release dir before re-assembling so stale erts subdirs
	// from prior builds (e.g. an old cross-platform release) can't
	// shadow the current host's erts and break the launcher.
	rmSync("_build/prod/rel", { recursive: true, force: true });
	run(["mix", "release", "--overwrite"], prod);

	const srcRelease = "_build/prod/rel/meerkat";
	if (!executable(join(srcRelease, "bin/meerkat"))) {
		process.stderr.write(`meerkat: release artefact missing at ${srcRelease}/bin/meerkat\n`);
		process.exit(1);
	}

	mkdirSync(paths.versions, { recursive: true });
	mkdirSync(paths.bin, { recursive: true });
	const finalDir = freeVersionDir(paths.versions, versionId(head, dirty, Math.floor(Date.now() / 1000)), existsSync);

	// Stamp clean builds with HEAD and dirty builds with a -wip suffix, so
	// the clean-tree idempotency check reuses only a release stamped with
	// exactly HEAD; a clean install then replaces a dirty build of that commit.
	writeFileSync(join(srcRelease, "INSTALLED_COMMIT"), `${head}${dirty ? "-wip" : ""}\n`);
	writeFileSync(
		join(srcRelease, "meerkat_version"),
		versionManifest(
			head,
			repoUrl(trimNewlines(output(["git", "config", "--get", "remote.origin.url"], env))),
			output(["git", "log", "--first-parent", "--format=%s", "-n", "15", head], env),
		),
	);

	// Stage beside the final home, then atomic-rename into place.
	const staging = join(paths.versions, `.staging.${process.pid}`);
	rmSync(staging, { recursive: true, force: true });
	run(["cp", "-R", srcRelease, staging], env);
	renameSync(staging, finalDir);
	console.log(`meerkat: built version ${basename(finalDir)} at ${finalDir}`);

	// Smoke-test the new release BEFORE flipping `current` at it: an
	// empty-staged-no-commit-msg invocation hits the auto-approve fast path
	// (cli.ex auto_approve_decision/2 staged-empty branch), approves without
	// binding a port, and proves the release boots end-to-end. Gating the
	// flip on it means a build that fails its smoke test leaves `current` on
	// the last good version and the next hook run rebuilds, instead of
	// activating a broken release that the idempotency check would then skip.
	console.log("meerkat: smoke-testing the new release in a throwaway repo...");
	const smoke = mkdtempSync(join(tmpdir(), "meerkat-smoke."));
	process.on("exit", () => rmSync(smoke, { recursive: true, force: true }));
	const smokeEnv = withoutGitVars(env);
	run(["git", "init", "-q", "-b", "main"], smokeEnv, smoke);
	run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"], smokeEnv, smoke);
	writeFileSync(join(smoke, "MSG"), "msg\n");
	// Invoke the new version's release exactly as the shepherd does, but
	// against the new dir directly, since `current` isn't pointed at it yet.
	run(
		[
			"bash",
			"-c",
			'source "$1"; meerkat_run_once "$2" eval "$MEERKAT_CLI_HALT" --commit-msg MSG --no-open',
			"smoke",
			join(process.cwd(), "bin/meerkat-attach"),
			join(finalDir, "bin/meerkat"),
		],
		{ ...smokeEnv, MEERKAT_PWD: smoke },
		smoke,
	);

	// Flip `current` at the smoke-tested version. A rename replaces the
	// `current` symlink itself rather than following it. Absolute target so
	// `readlink current` resolves standalone.
	const tmpLink = `${paths.current}.tmp.${process.pid}`;
	rmSync(tmpLink, { force: true });
	symlinkSync(finalDir, tmpLink);
	renameSync(tmpLink, paths.current);

	// The shepherd below sources this, so this lands first.
	copyFileSync("bin/meerkat-attach", `${paths.attach}.tmp.${process.pid}`);
	renameSync(`${paths.attach}.tmp.${process.pid}`, paths.attach);

	// Install the shepherd via temp + atomic rename: a shepherd a review is
	// already running keeps its old inode (bash reads the script by offset
	// as it loops), so replacing the path can't corrupt it mid-review.
	const shepherdTmp = `${paths.shepherd}.tmp.${process.pid}`;
	copyFileSync("bin/meerkat-shepherd", shepherdTmp);
	run(["chmod", "+x", shepherdTmp], env);
	renameSync(shepherdTmp, paths.shepherd);

	writeFileSync(paths.wrapper, expected);
	run(["chmod", "+x", paths.wrapper], env);

	console.log(`meerkat: installed ${paths.wrapper} -> ${paths.shepherd} -> ${paths.current}`);

	// GC old versions. Also retire the pre-versioning `release/` dir once
	// no live BEAM is reading it (migration cleanup).
	const commands = psCommands();
	for (const dir of gcVictims(versionDirs(paths.versions), finalDir, readlinkOr(paths.current), KEEP_VERSIONS, (d) =>
		dirInUse(commands, d),
	)) {
		rmSync(dir, { recursive: true, force: true });
	}

	const legacy = join(paths.share, "release");
	if (existsSync(legacy) && statSync(legacy).isDirectory() && !dirInUse(psCommands(), legacy)) {
		rmSync(legacy, { recursive: true, force: true });
	}

	console.log("meerkat: done.");
}

if (import.meta.main) install(process.argv.slice(2));

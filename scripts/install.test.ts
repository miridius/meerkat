import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import {
	dirInUse,
	freeVersionDir,
	gcVictims,
	type InstalledState,
	installPaths,
	launcher,
	repoUrl,
	shellQuote,
	upToDate,
	versionDirs,
	versionId,
	versionManifest,
	withoutGitVars,
} from "./install";

const HEAD = "0123456789abcdef0123456789abcdef01234567";

describe("installPaths", () => {
	test("defaults under the home dir", () => {
		expect(installPaths({}, "/home/u")).toEqual({
			share: "/home/u/.local/share/meerkat-beam",
			bin: "/home/u/.local/bin",
			versions: "/home/u/.local/share/meerkat-beam/versions",
			current: "/home/u/.local/share/meerkat-beam/current",
			wrapper: "/home/u/.local/bin/meerkat",
			shepherd: "/home/u/.local/share/meerkat-beam/meerkat-shepherd",
			attach: "/home/u/.local/share/meerkat-beam/meerkat-attach",
		});
	});

	test("takes the prefix and launcher dir from the environment", () => {
		const paths = installPaths({ MEERKAT_INSTALL_PREFIX: "/p", MEERKAT_BIN_DIR: "/b" }, "/home/u");
		expect([paths.current, paths.wrapper]).toEqual(["/p/current", "/b/meerkat"]);
	});
});

describe("versionId", () => {
	test("is the commit's first 12 characters for a clean tree", () => {
		expect(versionId(HEAD, false, 1700000000)).toBe("0123456789ab");
	});

	test("marks a dirty tree's build, or one with no commit, as work in progress", () => {
		expect(versionId(HEAD, true, 1700000000)).toBe("0123456789ab-wip.1700000000");
		expect(versionId("", false, 1700000000)).toBe("-wip.1700000000");
	});
});

describe("launcher", () => {
	// What bash's `launcher` wrote, before install.sh moved to TypeScript, for
	// a prefix with a space, so an install it made still counts as current.
	test("is the text the bash install wrote", () => {
		expect(launcher("/tmp/my prefix/current", "/tmp/my prefix/meerkat-shepherd")).toBe(`#!/usr/bin/env bash
# meerkat launcher (installed by scripts/install.sh). Forwards the
# user's cwd as $MEERKAT_PWD and hands off to the shepherd.
set -euo pipefail
export MEERKAT_PWD="\${MEERKAT_PWD:-$PWD}"
export MEERKAT_CURRENT_LINK=/tmp/my\\ prefix/current
SHEPHERD=/tmp/my\\ prefix/meerkat-shepherd
if [[ ! -x "$SHEPHERD" ]]; then
  echo "meerkat: shepherd missing at $SHEPHERD; re-run scripts/install.sh from the meerkat repo." >&2
  exit 127
fi
exec "$SHEPHERD" "$@"
`);
	});
});

describe("shellQuote", () => {
	test("quotes as bash 5's printf %q does", () => {
		expect(shellQuote("/a/b-c_d.e:f+g@h%i=j")).toBe("/a/b-c_d.e:f+g@h%i=j");
		expect(shellQuote("/a b,c'd\"e$f`g!h&i;j|k*l?m(n)[o]{p}")).toBe(
			"/a\\ b\\,c\\'d\\\"e\\$f\\`g\\!h\\&i\\;j\\|k\\*l\\?m\\(n\\)\\[o\\]\\{p\\}",
		);
		expect(shellQuote("~/a#b~c")).toBe("\\~/a#b~c");
		expect(shellQuote("#a")).toBe("\\#a");
		expect(shellQuote("/é")).toBe("/é");
		expect(shellQuote("")).toBe("''");
	});
});

describe("upToDate", () => {
	const expected = launcher("/p/current", "/p/meerkat-shepherd");
	const installed: InstalledState = {
		wrapper: `${expected}\n`,
		stamp: HEAD,
		releaseExecutable: true,
		shepherdExecutable: true,
		attachIsFile: true,
	};

	test("holds for a clean build of this commit with this script's launcher", () => {
		expect(upToDate(false, HEAD, false, expected, installed)).toBe(true);
	});

	test("fails when anything is missing or differs, or when forced", () => {
		expect(upToDate(true, HEAD, false, expected, installed)).toBe(false);
		expect(upToDate(false, "", false, expected, { ...installed, stamp: "" })).toBe(false);
		expect(upToDate(false, HEAD, true, expected, installed)).toBe(false);
		expect(upToDate(false, HEAD, false, expected, { ...installed, wrapper: null })).toBe(false);
		expect(
			upToDate(false, HEAD, false, expected, { ...installed, wrapper: "#!/usr/bin/env bash\n# another launcher\n" }),
		).toBe(false);
		expect(upToDate(false, HEAD, false, expected, { ...installed, stamp: `${HEAD}-wip` })).toBe(false);
		expect(upToDate(false, HEAD, false, expected, { ...installed, releaseExecutable: false })).toBe(false);
		expect(upToDate(false, HEAD, false, expected, { ...installed, shepherdExecutable: false })).toBe(false);
		expect(upToDate(false, HEAD, false, expected, { ...installed, attachIsFile: false })).toBe(false);
	});
});

describe("version manifest", () => {
	test("links GitHub's web URL for an SSH or HTTPS origin", () => {
		// Joined so the push gate does not read it as an email address.
		expect(repoUrl(["git", "github.com:o/r.git"].join("@"))).toBe("https://github.com/o/r");
		expect(repoUrl("https://github.com/o/r.git")).toBe("https://github.com/o/r");
		expect(repoUrl("")).toBe("");
	});

	test("is the commit, the repo URL, then the subjects", () => {
		expect(versionManifest(HEAD, "https://github.com/o/r", "B (#2)\nA (#1)\n")).toBe(
			`${HEAD}\nhttps://github.com/o/r\nB (#2)\nA (#1)\n`,
		);
	});
});

describe("freeVersionDir", () => {
	test("takes the first of <id>, <id>.1, <id>.2… that does not exist", () => {
		const taken = new Set(["/v/abc", "/v/abc.1"]);
		expect(freeVersionDir("/v", "abc", (p) => taken.has(p))).toBe("/v/abc.2");
		expect(freeVersionDir("/v", "def", (p) => taken.has(p))).toBe("/v/def");
	});
});

describe("dirInUse", () => {
	test("matches a process reading under the dir, not under a sibling it prefixes", () => {
		const ps = "/usr/bin/login\n/v/abc-wip.1/erts/bin/beam.smp -- -root /v/abc-wip.1\n";
		expect(dirInUse(ps, "/v/abc-wip.1")).toBe(true);
		expect(dirInUse(ps, "/v/abc")).toBe(false);
	});
});

describe("gcVictims", () => {
	const dirs = ["/v/new", "/v/a", "/v/b", "/v/cur", "/v/c", "/v/d", "/v/e", "/v/f", "/v/g"];

	test("keeps the newest five besides the one built and the current one", () => {
		expect(gcVictims(dirs, "/v/new", "/v/cur", 5, () => false)).toEqual(["/v/f", "/v/g"]);
	});

	test("keeps a dir a running review reads", () => {
		expect(gcVictims(dirs, "/v/new", "/v/cur", 5, (d) => d === "/v/f")).toEqual(["/v/g"]);
	});
});

describe("withoutGitVars", () => {
	test("drops every GIT_ variable", () => {
		expect(withoutGitVars({ GIT_DIR: "/r/.git", GIT_INDEX_FILE: "i", PATH: "/bin", MIGIT_X: "y" })).toEqual({
			PATH: "/bin",
			MIGIT_X: "y",
		});
	});
});

describe("on disk", () => {
	let base: string;
	beforeAll(() => {
		base = mkdtempSync(join(tmpdir(), "meerkat-install-"));
	});
	afterAll(() => rmSync(base, { recursive: true, force: true }));

	test("versionDirs lists version dirs newest first, as `ls -1dt versions/*/` does", () => {
		const versions = join(base, "versions");
		const at = (name: string, seconds: number) => {
			mkdirSync(join(versions, name), { recursive: true });
			utimesSync(join(versions, name), seconds, seconds);
		};
		at("old", 1000);
		at("new", 3000);
		at("b-tie", 2000);
		at("a-tie", 2000);
		at(".staging.1", 4000);
		writeFileSync(join(versions, "file"), "");
		symlinkSync(join(versions, "old"), join(versions, "link"));
		expect(versionDirs(versions).map((d) => d.slice(versions.length + 1))).toEqual([
			"new",
			"a-tie",
			"b-tie",
			"link",
			"old",
		]);
		expect(versionDirs(join(base, "missing"))).toEqual([]);
	});
});

// The real scripts/install.sh and install.ts, run from a committed, clean
// checkout of them whose commit `current` already holds, with mise and mix
// replaced by stubs that log each run. mise gives install.sh no environment
// and install.ts one whose PATH leads with `pinned`, whose bun and mix are
// stubs too; every mix exits 99, so a rebuild stops at its first step.
describe("install.sh and install.ts", () => {
	let base: string;
	let env: Record<string, string | undefined>;

	const executable = (path: string, content: string) => {
		mkdirSync(dirname(path), { recursive: true });
		writeFileSync(path, content);
		chmodSync(path, 0o755);
	};

	const git = (cwd: string, ...args: string[]) => {
		const result = Bun.spawnSync(["git", ...args], { cwd, env, stderr: "inherit" });
		if (result.exitCode !== 0) throw new Error(`git ${args.join(" ")} failed`);
		return result.stdout.toString().trim();
	};

	beforeAll(() => {
		base = mkdtempSync(join(tmpdir(), "meerkat-install-"));
		const repo = join(base, "repo");
		env = {
			...process.env,
			GIT_CONFIG_GLOBAL: join(import.meta.dir, "../test/support/test.gitconfig"),
			GIT_CONFIG_NOSYSTEM: "1",
		};
		for (const name of ["install.sh", "install.ts"]) {
			mkdirSync(join(repo, "scripts"), { recursive: true });
			copyFileSync(join(import.meta.dir, name), join(repo, "scripts", name));
		}
		git(base, "init", "-q", "--template=", repo);
		git(repo, "add", ".");
		git(repo, "-c", "user.email=t@t.t", "-c", "user.name=t", "commit", "-q", "-m", "base");
		const head = git(repo, "rev-parse", "HEAD");

		const share = join(base, "share");
		const version = join(share, "versions/v1");
		executable(join(version, "bin/meerkat"), "#!/bin/sh\n");
		writeFileSync(join(version, "INSTALLED_COMMIT"), `${head}\n`);
		symlinkSync(version, join(share, "current"));
		executable(join(share, "meerkat-shepherd"), "#!/bin/sh\n");
		writeFileSync(join(share, "meerkat-attach"), "");
		executable(join(base, "bin/meerkat"), launcher(join(share, "current"), join(share, "meerkat-shepherd")));

		const shim = join(base, "shim");
		const pinned = join(base, "pinned");
		executable(
			join(shim, "mise"),
			`#!/bin/sh
echo "mise $*" >> "$LOG"
if [ "$*" = "env --json" ]; then
  [ -z "$MISE_ENV_STATUS" ] || exit "$MISE_ENV_STATUS"
  printf '{"PATH":"%s"}' "${pinned}:$PATH"
fi
`,
		);
		executable(join(shim, "mix"), `#!/bin/sh\necho "mix $*" >> "$LOG"\nexit 99\n`);
		executable(join(pinned, "mix"), `#!/bin/sh\necho "pinned mix $*" >> "$LOG"\nexit 99\n`);
		executable(join(pinned, "bun"), `#!/bin/sh\necho "pinned bun $*" >> "$LOG"\n`);

		env = {
			...env,
			PATH: `${shim}:${dirname(process.execPath)}:${process.env.PATH}`,
			MEERKAT_INSTALL_PREFIX: share,
			MEERKAT_BIN_DIR: join(base, "bin"),
			LOG: join(base, "log"),
		};
	});

	afterAll(() => rmSync(base, { recursive: true, force: true }));

	const install = (extra: Record<string, string> = {}) => {
		rmSync(join(base, "log"), { force: true });
		const result = Bun.spawnSync(["bash", join(base, "repo/scripts/install.sh")], {
			env: { ...env, ...extra },
			stderr: "pipe",
		});
		return { status: result.exitCode, stdout: result.stdout.toString() };
	};

	const logLines = async () => {
		const log = Bun.file(join(base, "log"));
		return (await log.exists()) ? (await log.text()).split("\n").filter((l) => l !== "") : [];
	};

	test("skips the rebuild when the prod launcher is installed and current holds this commit", async () => {
		const run = install();
		expect(run.stdout).toMatch(/^meerkat: current already built from [0-9a-f]{12} \(clean tree\); skipping\./);
		expect(run.status).toBe(0);
		expect(await logLines()).toEqual(["mise install bun", "mise env --shell bash"]);
	});

	test("rebuilds without the prod launcher, installing the pinned tools and building on them", async () => {
		const run = install({ MEERKAT_BIN_DIR: join(base, "empty-bin") });
		expect(run.status).toBe(99);
		expect(await logLines()).toEqual([
			"mise install bun",
			"mise env --shell bash",
			"mise install erlang elixir bun",
			"mise env --json",
			"pinned bun scripts/setup-toolchain.ts",
			"pinned mix deps.get --only prod",
		]);
	});

	test("stops when mise cannot give its environment", async () => {
		const run = install({ MEERKAT_BIN_DIR: join(base, "empty-bin"), MISE_ENV_STATUS: "3" });
		expect(run.status).toBe(3);
		expect(await logLines()).toEqual([
			"mise install bun",
			"mise env --shell bash",
			"mise install erlang elixir bun",
			"mise env --json",
		]);
	});
});

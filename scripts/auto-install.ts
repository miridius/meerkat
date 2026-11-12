// Shared guard for the lefthook post-merge / post-checkout hooks:
// (re)install meerkat, and refresh the dev and test envs' deps and builds,
// only when HEAD is on `main`. scripts/install.sh is idempotent (it skips
// the rebuild when the release is already built from the current commit),
// so firing this on every `main` checkout is cheap — only a genuine commit
// change triggers the minutes-long build.
//
// Why two hooks: `post-merge` catches `git pull` / `git merge`;
// `post-checkout` catches `git switch main` / `git checkout main` — the
// path a GitHub squash-merge takes, since it lands on origin/main, never a
// local merge. `git fetch origin main:main` and `git reset` fire neither
// hook, so run scripts/install.sh after them.

import { join } from "node:path";

type Env = Record<string, string | undefined>;

// What to do for the branch `git rev-parse --abbrev-ref HEAD` named, or ""
// when it failed: install on `main`, otherwise say why not.
export function plan(branch: string): { install: true } | { install: false; message: string } {
	if (branch === "main") return { install: true };
	if (branch === "") return { install: false, message: "meerkat auto-install: couldn't resolve HEAD; skipping." };
	return { install: false, message: `meerkat auto-install: HEAD=${branch} (not main); skipping.` };
}

// `env` without the variables `git rev-parse --local-env-vars` lists.
export function withoutVars(env: Env, names: string): Env {
	const drop = new Set(names.split("\n").filter((n) => n !== ""));
	return Object.fromEntries(Object.entries(env).filter(([name]) => !drop.has(name)));
}

if (import.meta.main) {
	process.chdir(join(import.meta.dir, ".."));
	const git = (...args: string[]) => {
		const result = Bun.spawnSync(["git", ...args], { stdout: "pipe", stderr: "ignore" });
		return result.exitCode === 0 ? result.stdout.toString().trim() : "";
	};
	const p = plan(git("rev-parse", "--abbrev-ref", "HEAD"));
	if (!p.install) {
		process.stderr.write(`${p.message}\n`);
		process.exit(0);
	}
	// Git exports GIT_DIR and friends to hooks; left set, they would point
	// git dependencies' checkouts at this repository.
	const gitFree = withoutVars(process.env, git("rev-parse", "--local-env-vars"));
	const run = (cmd: string[], env: Env) => {
		const code = Bun.spawnSync(cmd, { env, stdio: ["inherit", "inherit", "inherit"] }).exitCode ?? 1;
		if (code !== 0) process.exit(code);
	};
	run(["bash", "scripts/install.sh"], process.env);
	// install.sh builds only prod. New Claude worktrees copy main's deps/
	// and _build/ (see .worktreeinclude), so also bring the dev and test
	// envs up to date, so a worktree's first dev review or test run
	// recompiles little. `mix deps.get` fetches every env's deps.
	run(["mix", "deps.get"], gitFree);
	for (const mixEnv of ["dev", "test"]) run(["mix", "compile"], { ...gitFree, MIX_ENV: mixEnv });
}

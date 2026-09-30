import { execFileSync } from "node:child_process";
import { basename, dirname, join } from "node:path";
import { MEERKAT_BIN, reapOrphanedBackends } from "./runner.js";

// Each test boots its own bin/meerkat-beam, whose pre-flight compiles the
// Elixir code and builds the assets when either is stale. Parallel workers
// booting a stale checkout would run those builds at once and collide in
// priv/static, so build once here, before any worker starts.
export default async function globalSetup(): Promise<void> {
	await reapOrphanedBackends();
	if (basename(MEERKAT_BIN) !== "meerkat-beam") return;

	const root = dirname(dirname(MEERKAT_BIN));
	const mixEnv = process.env.MIX_ENV ?? "dev";
	const env = { ...process.env, MIX_ENV: mixEnv };
	execFileSync("mix", ["compile", "--no-warnings-as-errors"], { cwd: root, env, stdio: "inherit" });
	execFileSync("bunx", ["vite", "build"], {
		cwd: join(root, "assets"),
		env: { ...env, MIX_BUILD_PATH: join(root, "_build", mixEnv) },
		stdio: "inherit",
	});
}

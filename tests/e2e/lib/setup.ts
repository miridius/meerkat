import { execFileSync } from "node:child_process";
import { basename } from "node:path";
import { MEERKAT_BIN, reapOrphanedBackends, reapOrphanedFixtures } from "./runner.js";

// With MEERKAT_BIN at bin/meerkat-beam, each test boots its own launcher,
// whose pre-flight compiles the Elixir code and builds the assets when
// either is stale. Parallel workers booting a stale checkout would run
// those builds at once and collide in priv/static, so run the launcher's
// own pre-flight once here, before any worker starts.
export default async function globalSetup(): Promise<void> {
	await reapOrphanedBackends();
	reapOrphanedFixtures();
	if (basename(MEERKAT_BIN) !== "meerkat-beam") {
		console.log(`e2e setup: not pre-building, MEERKAT_BIN=${MEERKAT_BIN} is not bin/meerkat-beam`);
		return;
	}
	execFileSync(MEERKAT_BIN, [], {
		env: { ...process.env, MEERKAT_BUILD_ONLY: "1" },
		stdio: "inherit",
	});
}

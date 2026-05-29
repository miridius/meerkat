import { defineConfig, devices } from "@playwright/test";

// Each test spawns its own meerkat process against a tmp git fixture
// (see tests/e2e/lib/runner.ts). There is no global webServer — meerkat
// is short-lived (it exits on decision) and per-test isolation is the
// point of the spec suite.
export default defineConfig({
	testDir: "./tests/e2e",
	timeout: 60_000,
	fullyParallel: true,
	forbidOnly: !!process.env.CI,
	// One retry locally + in CI absorbs the cold-start variance — first
	// pass occasionally times out when the launcher's mix-run boot +
	// 1.7MB JS bundle parse stack up on a busy machine. The retry runs
	// against a warmed module cache and is reliably green.
	retries: 1,
	// Cap workers at 2 even locally. Each meerkat spawn is a fresh
	// `mix run --no-start` BEAM boot (~4-8s); parallelism beyond two
	// concurrent boots saturates the system and pushes per-test cold
	// start past the action timeout.
	workers: process.env.CI ? 2 : 2,
	reporter: process.env.CI ? "github" : "list",
	use: {
		// 20s per action (Playwright's default `actionTimeout` is 0
		// / unbounded). Bounds individual interactions so a hung
		// click fails fast instead of consuming the whole 60s test
		// budget. The first interaction after a freshly-spawned
		// meerkat takes the brunt: BEAM cold-start (~1-3s for
		// module loading) + 1.7MB JS bundle download + parse +
		// LiveSvelte hydration. Cumulative sequential runs can hit
		// ~10s on a busy machine; 20s leaves headroom.
		actionTimeout: 20_000,
		trace: "retain-on-failure",
		screenshot: "only-on-failure",
		video: "retain-on-failure",
	},
	projects: [
		{
			name: "chromium",
			use: { ...devices["Desktop Chrome"] },
		},
	],
});

import { defineConfig, devices } from "@playwright/test";

// Each test spawns its own meerkat process against a tmp git fixture
// (see tests/e2e/lib/runner.ts). There is no global webServer — meerkat
// is short-lived (it exits on decision) and per-test isolation is the
// point of the spec suite.
export default defineConfig({
	testDir: "./tests/e2e",
	// The harness's own tests (tests/e2e/lib/*.test.ts) run under `bun test`.
	testMatch: "*.spec.ts",
	// Setup reaps backends left by earlier runs killed before teardown, and
	// builds the checkout under test once; teardown reaps any backends this
	// run left behind.
	globalSetup: "./tests/e2e/lib/setup.ts",
	globalTeardown: "./tests/e2e/lib/reap.ts",
	timeout: 60_000,
	fullyParallel: true,
	forbidOnly: !!process.env.CI,
	// One retry locally + in CI absorbs the cold-start variance — first
	// pass occasionally times out when the launcher's mix-run boot +
	// 1.7MB JS bundle parse stack up on a busy machine. The retry runs
	// against a warmed module cache and is reliably green.
	retries: 1,
	// Tests spend most of their time waiting on a BEAM boot or a page load,
	// so workers overlap well: on 18 cores the suite took 107s on 1 worker
	// and 35s on 9 with other work loading the machine to 20-40. Locally,
	// half the cores (Playwright's own default).
	workers: process.env.CI ? 2 : "50%",
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

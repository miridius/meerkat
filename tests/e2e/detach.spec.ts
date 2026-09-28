import { chmodSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Page } from "@playwright/test";
import { makeFixture } from "./lib/fixture";
import { type Runner, startMeerkat } from "./lib/runner";
import { expect, test } from "./lib/test";

async function addGlobalComment(page: Page, body: string): Promise<void> {
	await page.getByRole("button", { name: "+ Add global comment" }).click();
	const form = page.locator(".comment-form");
	await form.locator("textarea").fill(body);
	await form.getByRole("button", { name: /^Issue$/ }).click();
	await form.getByRole("button", { name: /^Add Global Comment$/ }).click();
	await expect(form).toBeHidden();
}

function backendPid(runner: Runner): number {
	const [dir] = readdirSync(runner.runsDir);
	return Number(readFileSync(join(runner.runsDir, dir, "pid"), "utf8").trim());
}

function alive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
}

test.describe("a review outlives the process that invoked it", () => {
	test("comments typed after the caller is killed reach the backend, and a rerun receives the decision", async ({
		page,
	}) => {
		const fixture = makeFixture();
		const first = await startMeerkat({ fixture, keepFixture: true });
		let second: Runner | undefined;
		try {
			await page.goto(first.url);
			await first.killCaller();
			expect(alive(backendPid(first)), "the backend survives its caller's SIGKILL").toBe(true);

			await addGlobalComment(page, "typed after the caller died");

			second = await startMeerkat({ fixture, keepFixture: true, runsDir: first.runsDir });
			expect(second.url, "the rerun attaches to the same backend").toBe(first.url);
			await expect(page.locator(".global-comments .note")).toContainText(
				"typed after the caller died",
			);

			await page.getByRole("button", { name: /^Send Feedback$/ }).click();
			const { code, stderr } = await second.awaitExit();
			expect(code, "the rerun exits with the decision's code").toBe(1);
			expect(stderr).toContain("User requested changes");
			expect(stderr).toContain("typed after the caller died");
		} finally {
			await second?.kill();
			await first.kill();
			rmSync(fixture.dir, { recursive: true, force: true });
		}
	});

	test("a decision clicked while no caller is attached is replayed to the next invocation", async ({
		page,
	}) => {
		const fixture = makeFixture();
		const first = await startMeerkat({ fixture, keepFixture: true });
		let second: Runner | undefined;
		try {
			await page.goto(first.url);
			await first.killCaller();
			await addGlobalComment(page, "held while nobody waited");
			await page.getByRole("button", { name: /^Send Feedback$/ }).click();
			await expect(page.getByRole("heading", { name: /^Feedback sent$/ })).toBeVisible();

			second = await startMeerkat({
				fixture,
				keepFixture: true,
				runsDir: first.runsDir,
				awaitUrl: false,
			});
			const { code, stderr } = await second.awaitExit();
			expect(code).toBe(1);
			expect(stderr, "a rerun collecting a held decision is not told to wait for a review").not.toContain(
				"Paused for human review",
			);

			const saved = /full feedback saved to (\S+) in case truncated/.exec(stderr);
			expect(saved, "the replayed outcome names the saved feedback file").not.toBeNull();
			const payload = readFileSync(saved?.[1] ?? "", "utf8");
			expect(payload).toContain("held while nobody waited");
			expect(
				stderr,
				"the replay prints the outcome the decision produced, verdict banner on both sides",
			).toContain(`${saved?.[0]} ──\n${payload}\n── `);
		} finally {
			await second?.kill();
			await first.kill();
			rmSync(fixture.dir, { recursive: true, force: true });
		}
	});

	test("a decision clicked after the process that ran meerkat is killed is held for the rerun", async ({
		page,
	}) => {
		const fixture = makeFixture();
		const first = await startMeerkat({ fixture, keepFixture: true, underParent: true });
		let second: Runner | undefined;
		try {
			await page.goto(first.url);
			await first.killParent();
			await first.awaitClose();

			await addGlobalComment(page, "sent after git was killed");
			await page.getByRole("button", { name: /^Send Feedback$/ }).click();
			await expect(page.getByRole("heading", { name: /^Feedback sent$/ })).toBeVisible();

			second = await startMeerkat({
				fixture,
				keepFixture: true,
				runsDir: first.runsDir,
				awaitUrl: false,
			});
			const { code, stderr } = await second.awaitExit();
			expect(code, "the rerun receives the decision, not a fresh review").toBe(1);
			expect(stderr).toContain("User requested changes");
		} finally {
			await second?.kill();
			await first.kill();
			rmSync(fixture.dir, { recursive: true, force: true });
		}
	});

	test("a second invocation of the same review takes it over from the first", async ({ page }) => {
		const fixture = makeFixture();
		const first = await startMeerkat({ fixture, keepFixture: true });
		let second: Runner | undefined;
		try {
			second = await startMeerkat({ fixture, keepFixture: true, runsDir: first.runsDir });
			const displaced = await first.awaitExit();
			expect(displaced.code, "the first invocation aborts its commit").toBe(1);
			expect(displaced.stderr).toContain("a later invocation of this review took it over");

			await page.goto(second.url);
			await page.getByRole("button", { name: /^Approve$/ }).click();
			const { code, stderr } = await second.awaitExit();
			expect(code).toBe(0);
			expect(stderr).toContain("The user approved your commit. Proceeding.");
		} finally {
			await second?.kill();
			await first.kill();
			rmSync(fixture.dir, { recursive: true, force: true });
		}
	});

	test("a rerun prints a warning from resolving its review once, before the banner", async () => {
		const fixture = makeFixture();
		const ghStubDir = mkdtempSync(join(tmpdir(), "meerkat-e2e-gh-"));
		writeFileSync(join(ghStubDir, "gh"), "#!/bin/sh\necho 'gh stub failure' >&2\nexit 1\n");
		chmodSync(join(ghStubDir, "gh"), 0o755);
		const opts = { fixture, keepFixture: true, pathPrefixes: [ghStubDir] };
		const first = await startMeerkat(opts);
		let second: Runner | undefined;
		try {
			await first.killCaller();
			second = await startMeerkat({ ...opts, runsDir: first.runsDir });
			await second.killCaller();
			const { stderr } = await second.awaitExit();

			const warning = "meerkat: warning — gh pr view failed: gh stub failure";
			expect(stderr.split(warning).length - 1, "the warning is printed once").toBe(1);
			expect(stderr.indexOf(warning)).toBeLessThan(stderr.indexOf("Paused for human review"));
		} finally {
			await second?.kill();
			await first.kill();
			rmSync(fixture.dir, { recursive: true, force: true });
			rmSync(ghStubDir, { recursive: true, force: true });
		}
	});

	for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const) {
		test(`a ${signal} to the caller's whole process group leaves the review for a rerun`, async ({
			page,
		}) => {
			const fixture = makeFixture();
			const first = await startMeerkat({ fixture, keepFixture: true, ownGroup: true });
			let second: Runner | undefined;
			try {
				const backend = backendPid(first);
				first.signalGroup(signal);
				await first.awaitExit();

				second = await startMeerkat({ fixture, keepFixture: true, runsDir: first.runsDir });
				expect(backendPid(second), "the rerun attaches to the backend the signal missed").toBe(
					backend,
				);
				await page.goto(second.url);
				await page.getByRole("button", { name: /^Approve$/ }).click();
				const { code, stderr } = await second.awaitExit();
				expect(code).toBe(0);
				expect(stderr).toContain("The user approved your commit. Proceeding.");
			} finally {
				await second?.kill();
				await first.kill();
				rmSync(fixture.dir, { recursive: true, force: true });
			}
		});
	}

	test("a Cancel clicked while no caller is attached is replayed to the next invocation", async ({
		page,
	}) => {
		const fixture = makeFixture();
		const first = await startMeerkat({ fixture, keepFixture: true });
		let second: Runner | undefined;
		try {
			await page.goto(first.url);
			await first.killCaller();
			await page.getByRole("button", { name: /^Cancel$/ }).click();
			await expect(page.getByRole("button", { name: /^Approve$/ })).toBeHidden();

			second = await startMeerkat({
				fixture,
				keepFixture: true,
				runsDir: first.runsDir,
				awaitUrl: false,
			});
			const { code, stderr } = await second.awaitExit();
			expect(code).toBe(1);
			expect(
				stderr.replace(/^meerkat: warning — .*\n/gm, ""),
				"besides its own warnings, the rerun prints only the cancelled sentence",
			).toBe(
				"Review cancelled — commit aborted, no feedback to act on.\n",
			);
		} finally {
			await second?.kill();
			await first.kill();
			rmSync(fixture.dir, { recursive: true, force: true });
		}
	});

	test("a caller whose backend dies exits 2 and rejects the commit", async () => {
		const fixture = makeFixture();
		const first = await startMeerkat({ fixture, keepFixture: true });
		try {
			const [dir] = readdirSync(first.runsDir);
			const [, beam] = readFileSync(join(first.runsDir, dir, "port"), "utf8").trim().split(" ");
			process.kill(backendPid(first), "SIGKILL");
			process.kill(Number(beam), "SIGKILL");

			const { code, stderr } = await first.awaitExit();
			expect(code).toBe(2);
			expect(stderr).toContain(
				"meerkat: the review backend died without a decision — defaulting to REJECT (commit aborted).",
			);
		} finally {
			await first.kill();
			rmSync(fixture.dir, { recursive: true, force: true });
		}
	});

	test("a review whose caller exited does not time out before a rerun collects it", async ({
		page,
	}) => {
		const fixture = makeFixture();
		const env = { MEERKAT_REVIEW_TIMEOUT: "3", MEERKAT_AUTO_APPROVE_ON_TIMEOUT: "true" };
		const first = await startMeerkat({ fixture, keepFixture: true, env });
		let second: Runner | undefined;
		try {
			await page.goto(first.url);
			await first.killCaller();
			// The backend checks the review deadline every 15 s. With a 3 s timeout
			// and auto-approve on, an armed deadline would approve by the first
			// check; this wait outlasts it.
			await page.waitForTimeout(17_000);
			await expect(
				page.getByRole("button", { name: /^Approve$/ }),
				"the orphaned review is still waiting for a decision",
			).toBeEnabled();

			second = await startMeerkat({ fixture, keepFixture: true, runsDir: first.runsDir, env });
			await page.getByRole("button", { name: /^Approve$/ }).click();
			const { code, stderr } = await second.awaitExit();
			expect(code).toBe(0);
			expect(stderr).toContain("The user approved your commit. Proceeding.");
		} finally {
			await second?.kill();
			await first.kill();
			rmSync(fixture.dir, { recursive: true, force: true });
		}
	});

	test("the countdown stops within three seconds of the caller being killed", async ({ page }) => {
		const fixture = makeFixture();
		const first = await startMeerkat({
			fixture,
			keepFixture: true,
			env: { MEERKAT_REVIEW_TIMEOUT: "1800" },
		});
		try {
			await page.goto(first.url);
			const countdown = page.locator(".review-countdown");
			await expect(countdown).toBeVisible();

			await first.killCaller();
			await expect(countdown, "the deadline is disarmed once no caller is attached").toHaveCount(
				0,
				{ timeout: 3_000 },
			);
		} finally {
			await first.kill();
			rmSync(fixture.dir, { recursive: true, force: true });
		}
	});

	test("a rerun started right after the click collects the decision without the banner", async ({
		page,
	}) => {
		const fixture = makeFixture();
		const first = await startMeerkat({ fixture, keepFixture: true });
		let second: Runner | undefined;
		try {
			await page.goto(first.url);
			await first.killCaller();
			await page.getByRole("button", { name: /^Approve$/ }).click();

			second = await startMeerkat({
				fixture,
				keepFixture: true,
				runsDir: first.runsDir,
				awaitUrl: false,
			});
			const { code, stderr } = await second.awaitExit();
			expect(code).toBe(0);
			expect(stderr).toContain("The user approved your commit. Proceeding.");
			expect(stderr, "a rerun collecting a decision is not told to wait for a review").not.toContain(
				"Paused for human review",
			);
		} finally {
			await second?.kill();
			await first.kill();
			rmSync(fixture.dir, { recursive: true, force: true });
		}
	});

	test("a rerun after the staged diff changed replaces the orphaned review", async ({ page }) => {
		const fixture = makeFixture();
		const first = await startMeerkat({ fixture, keepFixture: true });
		let second: Runner | undefined;
		try {
			await first.killCaller();
			const orphan = backendPid(first);

			writeFileSync(join(fixture.dir, "NOTES.md"), "rewritten after the caller died\n");
			fixture.git("add", "NOTES.md");

			second = await startMeerkat({ fixture, keepFixture: true, runsDir: first.runsDir });
			expect(alive(orphan), "the orphaned backend has exited").toBe(false);

			await page.goto(second.url);
			await expect(page.locator("body")).toContainText("rewritten after the caller died");
		} finally {
			await second?.kill();
			await first.kill();
			rmSync(fixture.dir, { recursive: true, force: true });
		}
	});

	test("a rerun after the staged diff changed replaces the review its attached caller waits on", async ({
		page,
	}) => {
		const fixture = makeFixture();
		const first = await startMeerkat({ fixture, keepFixture: true });
		let second: Runner | undefined;
		try {
			writeFileSync(join(fixture.dir, "NOTES.md"), "rewritten while the first caller waits\n");
			fixture.git("add", "NOTES.md");

			second = await startMeerkat({ fixture, keepFixture: true, runsDir: first.runsDir });
			const replaced = await first.awaitExit();
			expect(replaced.code, "the first invocation aborts its commit").toBe(1);
			expect(replaced.stderr).toContain("this review's diff or commit message changed");

			await page.goto(second.url);
			await expect(page.locator("body")).toContainText("rewritten while the first caller waits");
			await page.getByRole("button", { name: /^Approve$/ }).click();
			const { code, stderr } = await second.awaitExit();
			expect(code, "the rerun collects the decision on the new review").toBe(0);
			expect(stderr).toContain("The user approved your commit. Proceeding.");
		} finally {
			await second?.kill();
			await first.kill();
			rmSync(fixture.dir, { recursive: true, force: true });
		}
	});
});

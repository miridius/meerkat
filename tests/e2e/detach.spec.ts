import { readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
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

			second = await startMeerkat({ fixture, keepFixture: true, runsDir: first.runsDir });
			const { code, stderr } = await second.awaitExit();
			expect(code).toBe(1);

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

	test("a review whose caller exited does not time out before a rerun collects it", async ({
		page,
	}) => {
		const fixture = makeFixture();
		const env = { MEERKAT_REVIEW_TIMEOUT: "3" };
		const first = await startMeerkat({ fixture, keepFixture: true, env });
		let second: Runner | undefined;
		try {
			await page.goto(first.url);
			await first.killCaller();
			await page.waitForTimeout(5_000);
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
});

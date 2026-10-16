import { mkdirSync, readdirSync, readFileSync, renameSync, rmSync, symlinkSync } from "node:fs";
import { join } from "node:path";
import { budget } from "./lib/budget";
import { makeFixture, ownedTmpDir } from "./lib/fixture";
import { type Runner, startMeerkat, startMeerkats } from "./lib/runner";
import { expect, test } from "./lib/test";

// The BEAM serving the review, from the "<port> <pid>" its serve dir records.
function servingPid(runner: Runner): string | undefined {
	const [dir] = readdirSync(runner.runsDir);
	try {
		return readFileSync(join(runner.runsDir, dir, "port"), "utf8").trim().split(" ")[1];
	} catch {
		return undefined;
	}
}

test.describe("a review that restarts onto a new version", () => {
	test("resumes with its ticks and comments, and waits for a click even with every file ticked Approved", async ({
		page,
	}) => {
		const versions = ownedTmpDir("meerkat-e2e-versions");
		mkdirSync(join(versions, "v1"));
		mkdirSync(join(versions, "v2"));
		const link = join(versions, "current");
		symlinkSync(join(versions, "v1"), link);
		const [meerkat, other] = await startMeerkats(
			{
				fixture: makeFixture({ files: { "a.txt": "one\n" } }),
				env: { MEERKAT_CURRENT_LINK: link },
				keepFixture: true,
			},
			{ fixture: makeFixture({ files: { "b.txt": "two\n" } }) },
		);
		let rerun: Runner | undefined;
		try {
			await page.goto(meerkat.url);
			await page.getByRole("button", { name: "+ Add global comment" }).click();
			const form = page.locator(".comment-form");
			await form.locator("textarea").fill("kept across the restart");
			await form.getByRole("button", { name: /^Issue$/ }).click();
			await form.getByRole("button", { name: /^Add Global Comment$/ }).click();
			await expect(form).toBeHidden();
			const approved = page.getByRole("checkbox", { name: "Approved" });
			await approved.check();

			// Another review loaded in the same browser replaces the session
			// cookie, which must not keep this tab from rejoining in place.
			const otherPage = await page.context().newPage();
			await otherPage.goto(other.url);
			await expect(otherPage.locator("[data-phx-main].phx-connected")).toBeVisible();

			// A full reload discards this flag; LiveView's history updates don't.
			await page.evaluate(() => {
				(window as unknown as { notReloaded: boolean }).notReloaded = true;
			});
			const before = servingPid(meerkat);
			// Repoint `current` the way an install does, atomically.
			symlinkSync(join(versions, "v2"), `${link}.new`);
			renameSync(`${link}.new`, link);

			let exited: { code: number | null; stderr: string } | undefined;
			void meerkat.awaitExit().then((r) => {
				exited = r;
			});
			await expect
				.poll(
					() => {
						if (exited) return `exited ${exited.code}: ${exited.stderr}`;
						const pid = servingPid(meerkat);
						return pid !== undefined && pid !== before ? "restarted" : "waiting";
					},
					{ timeout: budget(30_000) },
				)
				.toBe("restarted");

			// The open page reconnects by itself, in place: the new BEAM verifies
			// its LiveView token with the shepherd's secret, and the build's
			// assets are unchanged, so it does not reload.
			await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible({ timeout: budget(30_000) });
			await expect(page.getByText("kept across the restart")).toBeVisible();
			await expect(approved).toBeChecked();
			expect(
				await page.evaluate(() => (window as unknown as { notReloaded?: boolean }).notReloaded),
			).toBe(true);

			await page.getByRole("button", { name: /^Approve with feedback$/ }).click();
			const { code, stderr } = await meerkat.awaitExit();
			expect(code).toBe(0);
			expect(stderr).not.toContain("auto-approving");
			expect(stderr).toContain("kept across the restart");

			rerun = await startMeerkat({
				fixture: meerkat.fixture,
				runsDir: meerkat.runsDir,
				awaitUrl: false,
			});
			const again = await rerun.awaitExit();
			expect(again.code).toBe(0);
			expect(again.stderr).toContain("auto-approving");
		} finally {
			await rerun?.kill();
			await other.kill();
			await meerkat.kill();
			meerkat.fixture.cleanup?.();
			rmSync(versions, { recursive: true, force: true });
		}
	});
});

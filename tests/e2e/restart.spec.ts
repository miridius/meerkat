import { mkdirSync, mkdtempSync, readdirSync, readFileSync, renameSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { makeFixture } from "./lib/fixture";
import { type Runner, startMeerkat } from "./lib/runner";
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
		const versions = mkdtempSync(join(tmpdir(), "meerkat-e2e-versions-"));
		mkdirSync(join(versions, "v1"));
		mkdirSync(join(versions, "v2"));
		const link = join(versions, "current");
		symlinkSync(join(versions, "v1"), link);
		const meerkat = await startMeerkat({
			fixture: makeFixture({ files: { "a.txt": "one\n" } }),
			env: { MEERKAT_CURRENT_LINK: link },
		});
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
					{ timeout: 30_000 },
				)
				.toBe("restarted");

			// The open page reconnects, and reloads, by itself.
			await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible({ timeout: 30_000 });
			await expect(page.getByText("kept across the restart")).toBeVisible();
			await expect(approved).toBeChecked();

			await page.getByRole("button", { name: /^Approve with feedback$/ }).click();
			const { code, stderr } = await meerkat.awaitExit();
			expect(code).toBe(0);
			expect(stderr).not.toContain("auto-approving");
			expect(stderr).toContain("kept across the restart");
		} finally {
			await meerkat.kill();
			rmSync(versions, { recursive: true, force: true });
		}
	});
});

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test } from "./lib/test";
import { startMeerkat } from "./lib/runner";

// The seam from a decision clicked in the browser, through the CLI and the
// launcher's attach stream, to what the calling agent reads: stderr and the
// exit code. How each decision maps to its code and text is covered by
// test/meerkat/cli_test.exs; the view's handlers by the LiveView tests.
test.describe("decision flow", () => {
	test("Send Feedback reaches the caller as exit 1 with the comments bracketed, saved to a file, and no server logs", async ({
		page,
	}) => {
		// The agent commonly head/tail's the feedback stream and sees only
		// a few comments. The banner (top and bottom, so either truncation
		// end survives) reports the true count and a path to the full copy
		// so the agent can recover everything it missed. keepFixture so the
		// log and feedback files survive meerkat's exit for inspection.
		const meerkat = await startMeerkat({ keepFixture: true });
		const logPath = join(meerkat.fixture.dir, ".git", "meerkat-precommit", "meerkat.log");
		try {
			await page.goto(meerkat.url);
			await expect(page).toHaveTitle("meerkat commit review");

			// First global comment uses "+ Add global comment"; once one
			// exists the control becomes "+ Add another".
			const addButtons = [/^\+ Add global comment$/, /^\+ Add another$/];
			for (const [i, body] of ["first finding here", "second finding here"].entries()) {
				await page.getByRole("button", { name: addButtons[i] }).click();
				// Scope to the form root — both the form and the page have a
				// "Cancel" button.
				const form = page.locator(".comment-form");
				await expect(form).toBeVisible();
				await form.locator("textarea").fill(body);
				await form.getByRole("button", { name: /^Issue$/ }).click();
				await form.getByRole("button", { name: /^Add Global Comment$/ }).click();
				// Form closes once the comment lands.
				await expect(form).toBeHidden();
			}

			await page.getByRole("button", { name: /^Send Feedback$/ }).click();

			const { code, stderr } = await meerkat.awaitExit();
			expect(code).toBe(1);

			// The outcome is stated in the output, not left to the exit code:
			// the banner states the verdict and the true count, bracketed top
			// and bottom so it survives at either truncation end.
			expect(stderr).toContain("2 comments");
			expect(stderr.match(/User requested changes/g)?.length).toBe(2);
			expect(stderr).toContain("first finding here");
			expect(stderr).toContain("second finding here");

			// The recovery file lives at the exact path the banner prints — a
			// per-review name under reviews/, not a clobberable fixed name.
			const m = stderr.match(/full feedback saved to (\S+) in case truncated/);
			expect(m).not.toBeNull();
			const feedbackPath = m?.[1] ?? "";
			expect(feedbackPath).toContain(join("meerkat-precommit", "reviews"));
			expect(existsSync(feedbackPath)).toBe(true);
			const saved = readFileSync(feedbackPath, "utf8");
			expect(saved).toContain("first finding here");
			expect(saved).toContain("second finding here");

			// The Phoenix/Bandit endpoint banner is the canonical noise line.
			// It must NOT reach the agent-facing stream...
			expect(stderr).not.toContain("MeerkatWeb.Endpoint");
			expect(stderr).not.toContain("[info]");
			// ...it was redirected to the logfile instead.
			expect(existsSync(logPath)).toBe(true);
			expect(readFileSync(logPath, "utf8")).toContain("MeerkatWeb.Endpoint");
		} finally {
			await meerkat.kill();
			meerkat.fixture.cleanup?.();
		}
	});
});

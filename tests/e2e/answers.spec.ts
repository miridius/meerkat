import { spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { makeFixture, sanitisedGitEnv } from "./lib/fixture";
import { MEERKAT_BIN, startMeerkat } from "./lib/runner";
import { expect, test } from "./lib/test";

// The seam is the launcher's `--answers` branch, which runs the BEAM in the
// foreground so the caller's stdin reaches it. The round-trip test also covers
// the browser's question form, hook refusal through the attach launcher, and
// answers reaching the browser. Which spellings of the flag take that branch is
// covered by test/scripts/shepherd_test.exs; validation and storage by the
// other ExUnit tests.
test.describe("meerkat --answers", () => {
	test("questions block a real git hook until answers sent through the launcher reach the next page", async ({ page }) => {
		// Seven real CLI invocations span two browser reviews. Budget their combined
		// runtime; each subprocess and review startup keeps its own bounded timeout.
		test.setTimeout(180_000);
		const fixture = makeFixture();
		const first = await startMeerkat({ fixture, keepFixture: true });
		let next: Awaited<ReturnType<typeof startMeerkat>> | undefined;
		try {
			await page.goto(first.url);
			for (const [i, question] of ["First question?", "Second question?"].entries()) {
				await page.getByRole("button", { name: i === 0 ? /^\+ Add global comment$/ : /^\+ Add another$/ }).click();
				const form = page.locator(".comment-form");
				await form.locator("textarea").fill(question);
				await form.getByRole("button", { name: /^Question$/ }).click();
				await form.getByRole("button", { name: /^Add Global Comment$/ }).click();
				await expect(form).toBeHidden();
			}
			await page.getByRole("button", { name: /^Send Feedback$/ }).click();
			const feedback = await first.awaitExit();
			expect(feedback.code).toBe(1);
			expect(feedback.stderr).toContain("answer 2 questions");
			await first.awaitClose();

			const hook = join(fixture.dir, ".git", "hooks", "pre-commit");
			mkdirSync(dirname(hook), { recursive: true });
			const quotedBin = `'${MEERKAT_BIN.replaceAll("'", "'\"'\"'")}'`;
			writeFileSync(hook, `#!/bin/sh\nexec ${quotedBin} --no-open\n`);
			chmodSync(hook, 0o755);
			const commit = () => spawnSync("git", ["commit", "-m", "Question round"], {
				cwd: fixture.dir, encoding: "utf8", timeout: 60_000,
				env: sanitisedGitEnv(),
			});
			let refused = commit();
			expect(refused.status).toBe(1);
			expect(refused.stderr).toContain("review refused because these questions are unanswered");
			expect(refused.stderr).toContain("First question?");
			expect(refused.stderr).toContain("Second question?");
			expect(refused.stderr).not.toContain("Paused for human review");

			const submit = (questions: string[]) => spawnSync(MEERKAT_BIN, ["--answers"], {
				cwd: fixture.dir, encoding: "utf8", timeout: 60_000, env: sanitisedGitEnv(),
				input: JSON.stringify({ answers: questions.map(question => ({ location: "global", question, answer: `Because **${question}**` })) }),
			});
			expect(submit(["First question?"]).status).toBe(0);
			refused = commit();
			expect(refused.status).toBe(1);
			expect(refused.stderr).toContain("Second question?");
			expect(refused.stderr).not.toContain("First question?");
			expect(refused.stderr).not.toContain("Paused for human review");

			expect(submit(["First question?", "Second question?"]).status).toBe(0);
			next = await startMeerkat({ fixture, keepFixture: true });
			await page.goto(next.url);
			const banner = page.locator("section.pending-answers");
			await expect(banner.getByRole("heading")).toHaveText("Pending answers (2)");
			await expect(banner.locator(".answer strong")).toHaveText(["First question?", "Second question?"]);
			await page.getByRole("button", { name: /^Approve$/ }).click();
			expect((await next.awaitExit()).code).toBe(0);
			await next.awaitClose();
			// The approved answers are not owed again after the banner clears.
			expect(commit().status).toBe(0);
		} finally {
			await next?.kill();
			await first.kill();
			fixture.cleanup();
		}
	});
});

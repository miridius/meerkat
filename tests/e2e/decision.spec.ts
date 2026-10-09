import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test } from "./lib/test";
import { startMeerkat } from "./lib/runner";

// The seam from a decision sent in the browser, through the CLI and the
// launcher's attach stream, to what the calling agent reads: stderr and the
// exit code. How each decision maps to its code and text is covered by
// test/meerkat/cli_test.exs; the view's handlers by the LiveView tests; the
// shortcut's key test by assets/ts/sendFeedbackShortcut.test.ts.
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
			// Desktop Chrome emulation sends a Windows user agent, so the page
			// detects a non-Mac platform even on a macOS runner.
			const mod = "Control";
			const sendFeedback = page.getByRole("button", { name: /^Send Feedback$/ });
			const hint = sendFeedback.locator(".shortcut-hint");
			await expect(hint).toHaveText("Ctrl+Shift+Enter");

			// Inside an open comment form the send shortcut neither submits
			// the form nor sends the feedback; the submit shortcut does submit.
			await page.getByRole("button", { name: /^\+ Add global comment$/ }).click();
			const form = page.locator(".comment-form");
			const textarea = form.locator("textarea");
			await textarea.fill("unsent draft");
			await textarea.press(`${mod}+Shift+Enter`);
			await expect(textarea).toHaveValue("unsent draft");

			await textarea.fill("first finding here");
			await textarea.press(`${mod}+Enter`);
			await expect(form).toBeHidden();
			await expect(page.locator(".comment-count")).toHaveText("1 comment");
			await expect(sendFeedback).toBeEnabled();
			await expect(hint).toHaveText("Ctrl+Shift+Enter");

			// Suggestion swaps the textarea for a CodeMirror editor whose
			// contents land in a fence tagged with the file's language: the
			// language-rust class is the observable end of the fileName →
			// languageFor → fence-tag chain.
			const fileSection = page.locator(".file-section").filter({ hasText: "src/main.rs" });
			await fileSection.getByRole("button", { name: /^\+ Add file comment$/ }).click();
			await expect(sendFeedback).toBeDisabled();
			await expect(form.locator("textarea"), "plain mode renders a single textarea").toHaveCount(1);
			await form.getByRole("button", { name: /^Suggestion$/ }).click();
			await expect(form.locator(".code-host .cm-editor")).toBeVisible();
			await expect(form.locator("textarea.prose"), "the prose textarea sits above the editor").toBeVisible();
			await form.locator(".code-host .cm-content").click();
			await page.keyboard.type("fn renamed() {}");
			await page.keyboard.press(`${mod}+Shift+Enter`);
			await expect(form.locator(".code-host .cm-line")).toHaveCount(1);
			await form.locator("textarea.prose").fill("second finding here");
			await form.getByRole("button", { name: /^Add File Comment$/ }).click();
			await expect(form).toBeHidden();
			await expect(page.locator(".comment-count")).toHaveText("2 comments");

			// Without the fence GitHub doesn't render a suggestion block.
			const card = fileSection.locator(".note.file-note").first();
			await expect(card).toContainText("second finding here");
			const code = card.locator("pre code.language-rust");
			await expect(code).toContainText("fn renamed() {}");
			await expect(code, "the prose stays outside the fence").not.toContainText("second finding here");

			await page.keyboard.press(`${mod}+Shift+Enter`);
			const { code: exit, stderr } = await meerkat.awaitExit();
			expect(exit).toBe(1);

			// The outcome is stated in the output, not left to the exit code:
			// the banner states the verdict and the true count, bracketed top
			// and bottom so it survives at either truncation end.
			expect(stderr).toContain("2 comments");
			expect(stderr.match(/User requested changes/g)?.length).toBe(2);
			expect(stderr).toContain("first finding here");
			expect(stderr).toContain("second finding here");
			expect(stderr).toContain("fn renamed() {}");
			expect(stderr).not.toContain("unsent draft");

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

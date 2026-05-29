import { spawn } from "node:child_process";
import { expect, test } from "./lib/test";
import { makeFixture } from "./lib/fixture";
import { startMeerkat } from "./lib/runner";

test.describe("decision flow", () => {
	test("Approve → meerkat exits 0", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			await expect(page.getByRole("button", { name: /^Approve$/ })).toBeVisible();
			await page.getByRole("button", { name: /^Approve$/ }).click();

			const { code, stderr } = await meerkat.awaitExit();
			expect(code).toBe(0);
			// Approval without comments prints the bare success message.
			expect(stderr).toContain("approved — commit proceeding");
		} finally {
			await meerkat.kill();
		}
	});

	test("Approve renders the post-decision 'Approved' view (window.close fallback)", async ({
		page,
	}) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			await page.getByRole("button", { name: /^Approve$/ }).click();

			// The done view shows the user-facing confirmation.
			// window.close() also fires from the same effect 500ms
			// later — Chromium blocks it for tabs not opened via
			// window.open(), so this assertion proves the
			// "you can close this tab" fallback path renders (not
			// the auto-close itself).
			await expect(page.getByRole("heading", { name: /^Approved$/ })).toBeVisible();
		} finally {
			await meerkat.kill();
		}
	});

	test("staged-diff with no file changes auto-approves and exits 0 immediately", async () => {
		// This is the "empty diff stalls" bug that historically triggered
		// the rewrite — Rust's behaviour is short-circuit auto-approve
		// BEFORE binding the review server, so meerkat never prints a
		// URL and never blocks. The default startMeerkat() helper waits
		// on a URL that never arrives, so we spawn meerkat directly here
		// (and hard-cap the exit wait to surface a regression as a
		// failed test rather than a 30s suite-timeout hang).
		const fixture = makeFixture({ files: {} });
		try {
			const proc = spawn(
				process.env.MEERKAT_BIN ?? "meerkat",
				["--commit-msg", fixture.commitMsgPath, "--no-open", "--port", "0"],
				{ cwd: fixture.dir, stdio: ["ignore", "pipe", "pipe"] },
			);

			let stderrBuf = "";
			proc.stderr?.on("data", (c: Buffer) => {
				stderrBuf += c.toString("utf8");
			});

			const exitCode = await new Promise<number | null>((resolve, reject) => {
				const timer = setTimeout(() => {
					if (!proc.killed) proc.kill("SIGTERM");
					reject(new Error(`auto-approve did not finish within 5s\nstderr:\n${stderrBuf}`));
				}, 5_000);
				proc.once("exit", (code) => {
					clearTimeout(timer);
					resolve(code);
				});
			});

			expect(exitCode).toBe(0);
			expect(stderrBuf).toContain("auto-approving");
			// No URL was ever printed — meerkat short-circuits before binding.
			expect(stderrBuf).not.toMatch(/review UI at http/);
		} finally {
			fixture.cleanup();
		}
	});

	test("Send Feedback with a global comment → exits 1, stderr contains the comment body", async ({
		page,
	}) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			await page.getByRole("button", { name: /^\+ Add global comment$/ }).click();
			// Scope to the form root — both the form and the page have a
			// "Cancel" button.
			const form = page.locator(".comment-form");
			await expect(form).toBeVisible();
			await form.locator("textarea").fill("please rename this variable to something clearer");
			await form.getByRole("button", { name: /^Issue$/ }).click();
			await form.getByRole("button", { name: /^Add Global Comment$/ }).click();

			// Form closes once the comment lands.
			await expect(form).toBeHidden();

			await page.getByRole("button", { name: /^Send Feedback$/ }).click();

			const { code, stderr } = await meerkat.awaitExit();
			expect(code).toBe(1);
			expect(stderr).toContain("please rename this variable to something clearer");
		} finally {
			await meerkat.kill();
		}
	});

	test("staged-diff with only linguist-generated files auto-approves", async () => {
		// `*.lock linguist-generated=true` in a committed `.gitattributes`
		// marks the staged lockfile as generated. The fast path treats
		// generated files as approved-for-short-circuit, so a
		// lockfile-only commit skips the UI entirely — no URL is ever
		// printed.
		const fixture = makeFixture({ files: {} });
		try {
			fixture.git("config", "user.email", "t@t.t");
			fixture.git("config", "user.name", "t");
			// Commit `.gitattributes` first — it must be in HEAD, not just
			// staged, so it's not part of the staged-diff under review.
			require("node:fs").writeFileSync(
				`${fixture.dir}/.gitattributes`,
				"*.lock linguist-generated=true\n",
			);
			fixture.git("add", ".gitattributes");
			fixture.git("commit", "-q", "-m", "seed attrs");
			require("node:fs").writeFileSync(`${fixture.dir}/bun.lock`, "fresh lockfile\n");
			fixture.git("add", "bun.lock");

			const proc = spawn(
				process.env.MEERKAT_BIN ?? "meerkat",
				["--commit-msg", fixture.commitMsgPath, "--no-open", "--port", "0"],
				{ cwd: fixture.dir, stdio: ["ignore", "pipe", "pipe"] },
			);

			let stderrBuf = "";
			proc.stderr?.on("data", (c: Buffer) => {
				stderrBuf += c.toString("utf8");
			});

			const exitCode = await new Promise<number | null>((resolve, reject) => {
				const timer = setTimeout(() => {
					if (!proc.killed) proc.kill("SIGTERM");
					reject(new Error(`generated-only auto-approve did not finish within 10s\nstderr:\n${stderrBuf}`));
				}, 10_000);
				proc.once("exit", (code) => {
					clearTimeout(timer);
					resolve(code);
				});
			});

			expect(exitCode).toBe(0);
			expect(stderrBuf).toMatch(/linguist-generated.*auto-approving/);
			expect(stderrBuf).not.toMatch(/review UI at http/);
		} finally {
			fixture.cleanup();
		}
	});

	test("Cancel wipes comments and exits 1 silently", async ({ page }) => {
		const meerkat = await startMeerkat();
		try {
			await page.goto(meerkat.url);

			await page.getByRole("button", { name: /^\+ Add global comment$/ }).click();
			const form = page.locator(".comment-form");
			await form.locator("textarea").fill("this should be wiped on cancel");
			await form.getByRole("button", { name: /^Issue$/ }).click();
			await form.getByRole("button", { name: /^Add Global Comment$/ }).click();
			await expect(form).toBeHidden();

			// Cancel wipes comments and submits a silent reject.
			// Multiple "Cancel" buttons would exist if the form were open;
			// closed form leaves only the page-level Cancel.
			await page.getByRole("button", { name: /^Cancel$/ }).click();

			const { code, stderr } = await meerkat.awaitExit();
			expect(code).toBe(1);
			// The comment was wiped before submission, so stderr does not
			// echo it.
			expect(stderr).not.toContain("this should be wiped on cancel");
		} finally {
			await meerkat.kill();
		}
	});
});

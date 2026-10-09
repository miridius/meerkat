import { execFileSync } from "node:child_process";
import {
	chmodSync,
	copyFileSync,
	mkdtempSync,
	readdirSync,
	readFileSync,
	rmSync,
	writeFileSync,
} from "node:fs";
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

// Like the index git hands the hook of `git commit -a` or `git commit <path>`: it
// stages EXTRA.md, which the repo's own index does not.
function temporaryIndex(dir: string, name: string): string {
	const index = join(dir, ".git", name);
	copyFileSync(join(dir, ".git", "index"), index);
	writeFileSync(join(dir, "EXTRA.md"), "only in the temporary index\n");
	execFileSync("git", ["add", "EXTRA.md"], {
		cwd: dir,
		env: { ...process.env, GIT_INDEX_FILE: index },
	});
	return index;
}

test.describe("a review outlives the process that invoked it", () => {
	// The backend leaves the caller's process group and session with setsid,
	// which keeps every signal to the group from reaching it, so one signal
	// stands for SIGINT, SIGTERM and SIGHUP alike.
	test("a SIGTERM to the caller's whole process group stops the countdown and leaves the review, with comments typed meanwhile, for a rerun", async ({
		page,
	}) => {
		const fixture = makeFixture();
		const first = await startMeerkat({ fixture, keepFixture: true, ownGroup: true });
		let second: Runner | undefined;
		try {
			await page.goto(first.url);
			const countdown = page.locator(".review-countdown");
			await expect(countdown).toBeVisible();

			const backend = backendPid(first);
			first.signalGroup("SIGTERM");
			expect(await first.awaitClose(), "the caller says the review lives on").toContain(
				`meerkat: stopped waiting (SIGTERM) before the review completed. The review is still open at ${first.url}; run the same command again to wait for its outcome.\n`,
			);
			expect((await first.awaitExit()).code, "the caller dies of the signal").toBeNull();
			await expect(countdown, "the deadline is disarmed once no caller is attached").toHaveCount(0);
			expect(alive(backend), "the backend survives the signal to its caller's group").toBe(true);

			await addGlobalComment(page, "typed after the caller died");

			const deadlines = join(fixture.dir, ".git", "meerkat-precommit", "deadlines");
			await expect
				.poll(() => readdirSync(deadlines).length, { message: "the first run anchored its deadline" })
				.toBe(1);
			const [firstRun] = readdirSync(deadlines);

			second = await startMeerkat({ fixture, keepFixture: true, runsDir: first.runsDir });
			expect(second.url, "the rerun attaches to the same backend").toBe(first.url);
			expect(backendPid(second), "the rerun attaches to the backend the signal missed").toBe(
				backend,
			);
			await expect(page.locator(".global-comments .note")).toContainText(
				"typed after the caller died",
			);

			// Each launcher run passes its own run id, so the rerun's deadline
			// is anchored apart from the first run's and gets a full window.
			await expect
				.poll(() => readdirSync(deadlines).length, {
					message: "the rerun anchored its deadline under its own directory",
				})
				.toBe(2);
			const secondRun = readdirSync(deadlines).find((run) => run !== firstRun);
			expect(secondRun, "the two runs are keyed apart").toBeDefined();

			await page.getByRole("button", { name: /^Send Feedback$/ }).click();
			const { code, stderr } = await second.awaitExit();
			expect(code, "the rerun exits with the decision's code").toBe(1);
			expect(stderr).toContain("User requested changes");
			expect(stderr).toContain("typed after the caller died");
			await expect
				.poll(() => readdirSync(deadlines), {
					message: "the decided review's deadline is cleared from the run that received it",
				})
				.not.toContain(secondRun);
		} finally {
			await second?.kill();
			await first.kill();
			rmSync(fixture.dir, { recursive: true, force: true });
		}
	});

	test("a decision clicked after the process that ran meerkat is killed is replayed whole to the rerun", async ({
		page,
	}) => {
		const fixture = makeFixture();
		const first = await startMeerkat({ fixture, keepFixture: true, underParent: true });
		let second: Runner | undefined;
		try {
			await page.goto(first.url);
			await first.killParent();
			expect(await first.awaitClose(), "the orphaned caller says the review lives on").toContain(
				`meerkat: the process that ran meerkat exited before the review completed. The review is still open at ${first.url}; run the same command again to wait for its outcome.\n`,
			);

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
			expect(stderr, "a rerun collecting a held decision is not told to wait for a review").not.toContain(
				"Paused for human review",
			);

			const banner = /── (User requested changes — 1 comment — full feedback saved to (\S+) in case truncated) ──/.exec(
				stderr,
			);
			expect(banner, "the replayed outcome names the saved feedback file").not.toBeNull();
			const payload = readFileSync(banner?.[2] ?? "", "utf8");
			expect(payload).toContain("sent after git was killed");
			expect(
				stderr.endsWith(`── ${banner?.[1]} ──\n${payload}\n── ${banner?.[1]} ──\n`),
				"the replay prints the outcome the decision produced, whole and last, verdict banner on both sides",
			).toBe(true);
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

	test("a SIGTERM to the BEAM ends the review at once and the caller exits 143", async ({ page }) => {
		const fixture = makeFixture();
		const first = await startMeerkat({ fixture, keepFixture: true });
		try {
			await page.goto(first.url);
			const [dir] = readdirSync(first.runsDir);
			const [, beam] = readFileSync(join(first.runsDir, dir, "port"), "utf8").trim().split(" ");
			const backend = backendPid(first);
			const signalled = Date.now();
			process.kill(Number(beam), "SIGTERM");

			const { code, stderr } = await first.awaitExit();
			expect(Date.now() - signalled, "no wait for open connections to close").toBeLessThan(5_000);
			expect(code).toBe(143);
			expect(stderr).toContain(
				"meerkat: received SIGTERM — stopping the review, defaulting to REJECT (commit aborted).",
			);
			expect(alive(Number(beam))).toBe(false);
			await expect.poll(() => alive(backend), "the shepherd does not restart the BEAM").toBe(false);
		} finally {
			await first.kill();
			rmSync(fixture.dir, { recursive: true, force: true });
		}
	});

	test("a decision made after the runs dir is deleted still reaches the caller and ends the backend", async ({
		page,
	}) => {
		const meerkat = await startMeerkat();
		const backend = backendPid(meerkat);
		try {
			await page.goto(meerkat.url);
			rmSync(meerkat.runsDir, { recursive: true, force: true });

			await page.getByRole("button", { name: /^Approve$/ }).click();
			const clicked = Date.now();

			const { code, stderr } = await meerkat.awaitExit();
			expect(code, stderr).toBe(0);
			expect(Date.now() - clicked, "the caller exits without waiting for the deleted run dir").toBeLessThan(5_000);
			await expect.poll(() => alive(backend), "the backend exits once the decision is delivered").toBe(false);
		} finally {
			await meerkat.kill();
			// With its run dir gone, `kill` cannot find the backend.
			try {
				process.kill(backend, "SIGTERM");
			} catch {}
		}
	});

	test("a rerun after the staged diff changed replaces the review its attached caller waits on", async ({
		page,
	}) => {
		const fixture = makeFixture();
		const first = await startMeerkat({ fixture, keepFixture: true });
		let second: Runner | undefined;
		try {
			const replacedBackend = backendPid(first);
			writeFileSync(join(fixture.dir, "NOTES.md"), "rewritten while the first caller waits\n");
			fixture.git("add", "NOTES.md");

			second = await startMeerkat({ fixture, keepFixture: true, runsDir: first.runsDir });
			expect(alive(replacedBackend), "the replaced review's backend has exited").toBe(false);
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

	// A message-only change keeps the same review_id, so the replacement
	// would otherwise load the held review's existing snapshot.
	test("a held decision's comments do not reappear in the review that replaces it after a message-only change", async ({
		page,
	}) => {
		const fixture = makeFixture();
		const first = await startMeerkat({ fixture, keepFixture: true, underParent: true });
		let second: Runner | undefined;
		try {
			const replacedBackend = backendPid(first);
			await page.goto(first.url);
			await first.killParent();
			await first.awaitClose();

			await addGlobalComment(page, "held for the old message");
			await page.getByRole("button", { name: /^Send Feedback$/ }).click();
			await expect(page.getByRole("heading", { name: /^Feedback sent$/ })).toBeVisible();

			writeFileSync(fixture.commitMsgPath, "A different subject\n");
			second = await startMeerkat({ fixture, keepFixture: true, runsDir: first.runsDir });
			expect(alive(replacedBackend), "the review holding the decision has been replaced").toBe(false);

			await page.goto(second.url);
			await expect(page.locator("body")).toContainText("A different subject");
			await expect(page.locator(".global-comments .note")).toHaveCount(0);
			await page.getByRole("button", { name: /^Approve$/ }).click();
			const { code, stderr } = await second.awaitExit();
			expect(code).toBe(0);
			expect(stderr, "the replacement review has no comments").toContain(
				"The user approved your commit. Proceeding.",
			);
		} finally {
			await second?.kill();
			await first.kill();
			rmSync(fixture.dir, { recursive: true, force: true });
		}
	});

	// Git exports GIT_INDEX_FILE to the hook: `.git/index` for `git commit`, a temporary
	// file holding what `git commit -a` or `git commit <path>` will commit otherwise.
	test("a retried `git commit <path>`, whose temporary index has a new name, is replayed the decision held for it", async ({
		page,
	}) => {
		const fixture = makeFixture();
		const firstIndex = temporaryIndex(fixture.dir, "next-index-1.lock");
		const first = await startMeerkat({
			fixture,
			keepFixture: true,
			underParent: true,
			env: { GIT_INDEX_FILE: firstIndex },
		});
		let second: Runner | undefined;
		try {
			await page.goto(first.url);
			await first.killParent();
			await first.awaitClose();
			rmSync(firstIndex);

			const approved = page
				.locator(".file-section")
				.filter({ hasText: "EXTRA.md" })
				.getByRole("checkbox", { name: "Approved" });
			await approved.click();
			// The tick appears immediately even if rejected; reload to see whether the review accepted it.
			await page.reload();
			await expect(approved).toBeChecked();

			await page.getByRole("button", { name: /^Approve$/ }).click();
			await expect(page.getByRole("heading", { name: /^Approved$/ })).toBeVisible();

			const retryIndex = temporaryIndex(fixture.dir, "next-index-2.lock");
			second = await startMeerkat({
				fixture,
				keepFixture: true,
				runsDir: first.runsDir,
				awaitUrl: false,
				env: { GIT_INDEX_FILE: retryIndex },
			});
			const { code, stderr } = await second.awaitExit();
			expect(code, "the retry receives the held decision").toBe(0);
			expect(stderr).toContain("The user approved your commit. Proceeding.");
			expect(stderr, "it attached to the review, not a fresh one").not.toContain(
				"Paused for human review",
			);
		} finally {
			await second?.kill();
			await first.kill();
			rmSync(fixture.dir, { recursive: true, force: true });
		}
	});

	test("a rerun given an index file with other staged content replaces the review", async ({
		page,
	}) => {
		const fixture = makeFixture();
		const temporary = temporaryIndex(fixture.dir, "next-index-1.lock");
		const first = await startMeerkat({
			fixture,
			keepFixture: true,
			env: { GIT_INDEX_FILE: temporary },
		});
		let second: Runner | undefined;
		try {
			const replacedBackend = backendPid(first);

			// Relative, as git hands it to the hook of a plain `git commit`.
			second = await startMeerkat({
				fixture,
				keepFixture: true,
				runsDir: first.runsDir,
				env: { GIT_INDEX_FILE: join(".git", "index") },
			});
			expect(alive(replacedBackend), "the review of the other index has exited").toBe(false);
			const replaced = await first.awaitExit();
			expect(replaced.code, "the first invocation aborts its commit").toBe(1);
			expect(replaced.stderr).toContain("diff or commit message changed");

			await page.goto(second.url);
			await expect(page.locator(".file-section").first()).toBeVisible();
			await expect(page.locator("body"), "the new review drops the old review's copy").not.toContainText(
				"EXTRA.md",
			);
			await page.getByRole("button", { name: /^Approve$/ }).click();
			const { code } = await second.awaitExit();
			expect(code, "the rerun collects the decision on the new review").toBe(0);
		} finally {
			await second?.kill();
			await first.kill();
			rmSync(fixture.dir, { recursive: true, force: true });
		}
	});
});
